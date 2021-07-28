#./setup.sh keystore_password sn_password serverip hostname image_tag

KEYSTORE_PASSWORD=$1
SN_PASSWORD=$2
SERVERIP=$3
HOSTNAME=$4
TAG=$5
KEYSTORE_NAME="dockerhost.keystore"

# Assert dependencies are installed
which openssl
which keytool
which docker

# Create Certificate Authority PEM
openssl genrsa -aes256 -passout pass:$KEYSTORE_PASSWORD -out ca-key.pem 4096
openssl req -passin pass:$KEYSTORE_PASSWORD -new -x509 -days 365 -key ca-key.pem -sha256 -out ca.pem
chmod 0400 ca-key.pem
chmod 0444 ca.pem

# Create the Server PEM
openssl genrsa -out server-key.pem 4096
openssl req -subj "/CN=$HOSTNAME" -new -key server-key.pem -out server.csr
echo "subjectAltName = DNS:$HOSTNAME,IP:$SERVERIP,IP:127.0.0.1" > extfile.cnf
openssl x509 -passin pass:$KEYSTORE_PASSWORD -req -days 365 -in server.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out server-cert.pem -extfile extfile.cnf
rm server.csr extfile.cnf ca.srl
chmod 0400 server-key.pem
chmod 0444 server-cert.pem

# Create the Client PEM
openssl genrsa -out client-key.pem 4096
openssl req -subj "/CN=example.com" -new -key client-key.pem -out client.csr
echo "extendedKeyUsage = clientAuth" > extfile.cnf
openssl x509 -passin pass:$KEYSTORE_PASSWORD -req -days 365 -in client.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out client-cert.pem -extfile extfile.cnf
rm client.csr extfile.cnf ca.srl
chmod 0400 client-key.pem
chmod 0444 client-cert.pem

# Create the Java Keystore
keytool -genkey -keyalg RSA -alias dse -keystore $KEYSTORE_NAME
keytool -delete -alias dse -keystore $KEYSTORE_NAME

# Import the CA certificate to the keystore
keytool -import -keystore $KEYSTORE_NAME -trustcacerts -alias ca -file ca.pem

# Import the Client Cert/Key pair
openssl pkcs12 -export -name clientkeypair -in client-cert.pem -inkey client-key.pem -out clientkeypair.p12
keytool -importkeystore -destkeystore $KEYSTORE_NAME -srckeystore clientkeypair.p12 -srcstoretype pkcs12 -alias clientkeypair
rm clientkeypair.p12

# Configure Docker
PWD=$(pwd)
echo "{\"tlscacert\":\"${PWD}/ca.pem\",\"tlscert\":\"${PWD}/server-cert.pem\",\"tlskey\":\"${PWD}/server-key.pem\",\"tlsverify\":true}" > /etc/docker/daemon.json

# Add the server keys to docker config
sudo mkdir -p /etc/systemd/system/docker.service.d/
{ echo "[Service]"; 
  echo " ExecStart=";
  echo " ExecStart=/usr/bin/dockerd -H tcp://0.0.0.0:2376"
} | sudo tee /etc/systemd/system/docker.service.d/10-expose-port.conf
sudo systemctl daemon-reload
sudo systemctl restart docker.service

# Enable local docker access
mkdir -pv ~/.docker
cp ca.pem ~/.docker
cp client-key.pem ~/.docker/key.pem
cp client-cert.pem ~/.docker/cert.pem

export DOCKER_HOST=tcp://${SERVERIP}:2376
export DOCKER_TLS_VERIFY=1
echo "export DOCKER_HOST=tcp://${SERVERIP}:2376 DOCKER_TLS_VERIFY=1" >> ~/.bash_profile

echo "Verifying that the API is up and connects successfully with the keys"
curl https://$SERVERIP:2376/images/json --cert ~/.docker/cert.pem --key ~/.docker/key.pem --cacert ~/.docker/ca.pem

docker info
docker pull ghcr.io/servicenow/atf-headless-runner:$TAG
docker swarm init

SECRET_ID=$(echo "ServiceNow password" | docker secret create sn_password -)

echo "***************** SUCCESS *****************"
echo "Docker Secret ID (put in sys_property sn_atf.headless.secret_id): $SECRET_ID"
echo "Keystore to import to Instance: $KEYSTORE_NAME"
echo "Your Keystore Password is: $KEYSTORE_PASSWORD"
echo "Run \"source ~/.bash_profile\" to run docker commands locally for this user"
#!/bin/bash

main() {
	check_env

	echo ":::::::Setting up Bosh-Director"
  deploy_director

	echo ":::::::Add Eirini routes to Director VM"
	add_eirini_routes

  echo ":::::::Setting up minikube"
	setup_minikube

	echo ":::::::Preaparing eirini release"
  prepare_eirini_release

	echo ":::::::Preaparing capi release"
	prepare_capi_release

	echo ":::::::Deploying CF and Eirini"
	deploy_cf_and_eirini

	echo ":::::::Setting routes to reach CF API"
	enable_cf_api

	echo ":::::::Setup CF environment"
	setup_cf_environment

	echo ":::::::Summary"
	summary
}

check_env() {
  echo "Using the following environment:"
	echo "BOSH_DEPLOYMENT: ${BOSH_DEPLOYMENT_DIR?"Environment variable BOSH_DEPLOYMENT_DIR not set"}"
	echo "CF_DEPLOYMENT: ${CF_DEPLOYMENT?"Environment variable CF_DEPLOYMENT not set"}"
	echo "EIRINI_RELEASE: ${EIRINI_RELEASE?"Environment variable EIRINI_RELEASE not set"}"
	echo "CAPI_RELEASE: ${CAPI_RELEASE?"Environment variable CAPI_RELEASE not set"}"
	echo "BOSH_DIRECTOR_ALIAS: ${BOSH_DIRECTOR_ALIAS?"Environment variable BOSH_DIRECTOR_ALIAS not set"}"
	echo "EIRINI_LITE: ${EIRINI_LITE?"Environment variable EIRINI_LITE (workspace) is not set"}"
}

deploy_director() {
  bosh create-env "$BOSH_DEPLOYMENT_DIR"/bosh.yml \
    --state "$BOSH_DEPLOYMENT_DIR"/state.json \
    -o "$BOSH_DEPLOYMENT_DIR"/virtualbox/cpi.yml \
    -o "$BOSH_DEPLOYMENT_DIR"/virtualbox/outbound-network.yml \
    -o "$BOSH_DEPLOYMENT_DIR"/bosh-lite.yml \
    -o "$BOSH_DEPLOYMENT_DIR"/bosh-lite-runc.yml \
    -o "$BOSH_DEPLOYMENT_DIR"/jumpbox-user.yml \
    --vars-store "$BOSH_DEPLOYMENT_DIR"/creds.yml \
    -v director_name="Bosh Lite Director" \
    -v internal_ip=192.168.50.6 \
    -v internal_gw=192.168.50.1 \
    -v internal_cidr=192.168.50.0/24 \
    -v outbound_network_name=NatNetwork

  bosh -e 192.168.50.6 --ca-cert <(bosh int "$BOSH_DEPLOYMENT_DIR"/creds.yml --path /director_ssl/ca) alias-env "$BOSH_DIRECTOR_ALIAS"

  export BOSH_CLIENT=admin
  bosh_client_secret=$(bosh int "$BOSH_DEPLOYMENT_DIR"/creds.yml --path /admin_password)
  export BOSH_CLIENT_SECRET=$bosh_client_secret

  bosh -e "$BOSH_DIRECTOR_ALIAS" env
}

# In order to make Eirini accessible from Kubernetes, we need two iptable rules on the director
# to redirect traffic to eirini opi (port 8085) and registry (port 8080)
add_eirini_routes(){
	bosh int "$BOSH_DEPLOYMENT_DIR"/creds.yml --path /jumpbox_ssh/private_key > "$BOSH_DEPLOYMENT_DIR"/jumpbox.key && chmod 600 "$BOSH_DEPLOYMENT_DIR"/jumpbox.key
  ssh -o "StrictHostKeyChecking no" jumpbox@192.168.50.6 -i "$BOSH_DEPLOYMENT_DIR"/jumpbox.key 'sudo iptables -t nat -I PREROUTING 2 -p tcp --dport 8090 -j DNAT --to 10.244.0.142:8085'
  ssh -o "StrictHostKeyChecking no" jumpbox@192.168.50.6 -i "$BOSH_DEPLOYMENT_DIR"/jumpbox.key 'sudo iptables -t nat -I PREROUTING 2 -p tcp --dport 8089 -j DNAT --to 10.244.0.142:8080'
}

# Minikube needs to be started in the same network as bosh-lite, s.t it is able to communicate to CF.
# Moreover it requires Eirini to be set as insecure-registry, otherwise Kubernetes will reject traffic from/to the registry
setup_minikube() {
  minikube start --host-only-cidr 192.168.50.1/24 --insecure-registry="10.244.0.142:8080"
}

prepare_eirini_release() {
	pushd "$EIRINI_RELEASE"
	git submodule update --init --recursive
	export GOPATH="$EIRINI_RELEASE"
  ./scripts/buildfs.sh
	bosh sync-blobs
	popd
}

prepare_capi_release() {
	pushd "$CAPI_RELEASE"
	git submodule update --init --recursive
	bosh sync-blobs
	popd
}


deploy_cf_and_eirini() {
	bosh -e "$BOSH_DIRECTOR_ALIAS"  update-cloud-config -n $CF_DEPLOYMENT/iaas-support/bosh-lite/cloud-config.yml

  bosh int "$CF_DEPLOYMENT"/cf-deployment.yml \
     -o "$CF_DEPLOYMENT"/operations/experimental/enable-bpm.yml \
     -o "$CF_DEPLOYMENT"/operations/experimental/use-bosh-dns.yml \
     -o "$CF_DEPLOYMENT"/operations/bosh-lite.yml \
     -o "$EIRINI_RELEASE"/operations/eirini-bosh-operations.yml \
     -o "$EIRINI_RELEASE"/operations/dev-version.yml \
		 -o "$EIRINI_RELEASE"/operations/capi-dev-version.yml \
     --vars-store "$CF_DEPLOYMENT"/deployment-vars.yml \
     --var=k8s_flatten_cluster_config="$(kubectl config view --flatten=true)" \
     -v system_domain=bosh-lite.com \
     -v cc_api=https://api.bosh-lite.com \
     -v kube_namespace="default" \
     -v kube_endpoint="no-endpoint" \
     -v nats_ip=10.244.0.129 \
     -v registry_address="10.244.0.142:8080" \
     -v eirini_ip=10.244.0.142 \
     -v eirini_address="http://eirini.bosh-lite.com:8090" \
     -v eirini_local_path="$EIRINI_RELEASE" \
		 -v capi_local_path="$CAPI_RELEASE" > "$EIRINI_LITE"/manifest.yml

	STEMCELL_VERSION=$(bosh int "$EIRINI_LITE"/manifest.yml --path /stemcells/alias=default/version)

	bosh -e "$BOSH_DIRECTOR_ALIAS" upload-stemcell https://bosh.io/d/stemcells/bosh-warden-boshlite-ubuntu-trusty-go_agent\?v\=$STEMCELL_VERSION

	bosh -e "$BOSH_DIRECTOR_ALIAS" deploy -d cf -n "$EIRINI_LITE"/manifest.yml
  verify_exit_code $? "Failed to deploy CF"
}

enable_cf_api(){
	echo "Need root password for setting routes:"
  if [ "$(uname)" = "Darwin" ]; then
    sudo route add -net 10.244.0.0/16 192.168.50.6
  elif [ "$(uname)" = "Linux" ]; then
    if type ip > /dev/null 2>&1; then
      sudo ip route add 10.244.0.0/16 via 192.168.50.6
    elif type route > /dev/null 2>&1; then
      sudo route add -net 10.244.0.0/16 gw  192.168.50.6
    else
      echo "ERROR adding route"
      exit 1
    fi
  fi
}

setup_cf_environment(){
	cf api api.bosh-lite.com --skip-ssl-validation
	verify_exit_code $? "failed to set api endpoint"

	cf_admin_pass=$(bosh int "$CF_DEPLOYMENT"/deployment-vars.yml --path /cf_admin_password)
	cf auth admin "$cf_admin_pass"
	verify_exit_code $? "failed to authenticate to CF"

  cf create-org eirini
	verify_exit_code $? "failed to authenticate to CF"

	cf target -o eirini
	verify_exit_code $? "failed to authenticate to CF"

	cf create-space dev
	verify_exit_code $? "failed to authenticate to CF"

	cf target -s dev
	verify_exit_code $? "failed to authenticate to CF"
}

verify_exit_code() {
	local exit_code=$1
	local error_msg=$2
	if [ "$exit_code" -ne 0 ]; then
		echo "$error_msg"
		exit 1
	fi
}

summary(){
	cat << EOF

      Welcome To:
      _/_/_/_/  _/_/_/  _/_/_/    _/_/_/  _/      _/  _/_/_/
     _/          _/    _/    _/    _/    _/_/    _/    _/
    _/_/_/      _/    _/_/_/      _/    _/  _/  _/    _/
   _/          _/    _/    _/    _/    _/    _/_/    _/
  _/_/_/_/  _/_/_/  _/    _/  _/_/_/  _/      _/  _/_/_/

  You are set and ready to use Eirini!

  CF:
  - Endpoint: api.bosh-lite.com
  - User: admin
  - Password: ${cf_admin_pass}
  - Org: eirini
  - Space: dev

  Bosh-Director:
  - alias: ${BOSH_DIRECTOR_ALIAS}
  - user: admin
  - secret: ${BOSH_CLIENT_SECRET}

  All apps are going to end up on your minikube cluster in the "default" namespace.

  Have fun! :)
EOF
}

main

#!/bin/bash

check_app_exists() {
  sleep 1

  echo "Checking if app exists..."
  if [ $(kubectl -n eirini-workloads get pods | grep the-app-guid | wc -l) -lt 1 ]; then
    echo "+-------------------------------"
    echo "| FAILED"
    echo "+-------------------------------"
    exit 1
  fi

  echo "+-------------------------------"
  echo "| SUCCESS"
  echo "+-------------------------------"
}

test_api() {
  trap 'kubectl -n eirini-workloads delete statefulsets --all' RETURN

  tls_crt="$(kubectl get secret -n eirini-core eirini-tls -o json | jq -r '.data["tls.crt"]' | base64 -d)"
  tls_key="$(kubectl get secret -n eirini-core eirini-tls -o json | jq -r '.data["tls.key"]' | base64 -d)"
  tls_ca="$(kubectl get secret -n eirini-core eirini-tls -o json | jq -r '.data["tls.ca"]' | base64 -d)"

  eirini_host="$(kubectl get nodes -o wide | tail -1 | awk '{ print $7 }')"

  echo "Creating an app via API"
  curl --cacert <(echo "$tls_ca") --key <(echo "$tls_key") --cert <(echo "$tls_crt") -k "https://$eirini_host:30085/apps/testapp" -X PUT -H "Content-Type: application/json" -d '{"guid": "the-app-guid","version": "0.0.0","ports" : [8080],"lifecycle": {"docker_lifecycle": {"image": "busybox","command": ["/bin/sleep", "100"]}},"instances": 1}'

  check_app_exists
}

test_crd() {
  echo "Creating an app via CRD"
  kubectl apply -f <<-EOF
apiVersion: eirini.cloudfoundry.org/v1
kind: LRP
metadata:
  name: testapp
  namespace: eirini-workloads
spec:
  guid: "the-app-guid"
  version: "version-1"
  processGUID: "30061986"
  appGUID: "the-app-guid"
  appName: "amazing"
  spaceName: "titan"
  orgName: "saturn"
  environment:
    FOO: "BAR"
  instances: 1
  lastUpdated: "never"
  ports:
  - 8080
  lifecycle:
    docker:
      image: "eirini/dorini"
EOF

  check_app_exists
}

echo "Cleaning up..."
kubectl -n eirini-workloads delete statefulsets --all

echo "Allowing nodeport 30085..."
gcloud compute firewall-rules create test-node-port --quiet --network lisbon --allow tcp:30085
trap 'gcloud compute firewall-rules delete --quiet test-node-port' EXIT

test_api
test_crd

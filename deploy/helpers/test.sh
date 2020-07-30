#!/bin/bash

set -e

test_api() {
  trap 'kubectl -n eirini-workloads delete statefulsets --all' RETURN
  tls_crt="$(kubectl get secret -n eirini-core eirini-tls -o json | jq -r '.data["tls.crt"]' | base64 -d)"
  tls_key="$(kubectl get secret -n eirini-core eirini-tls -o json | jq -r '.data["tls.key"]' | base64 -d)"
  tls_ca="$(kubectl get secret -n eirini-core eirini-tls -o json | jq -r '.data["tls.ca"]' | base64 -d)"

  echo "Creating an app via API"
  curl --cacert <(echo "$tls_ca") --key <(echo "$tls_key") --cert <(echo "$tls_crt") -k https://172.18.0.2:8085/apps/app-guid -X PUT -H "Content-Type: application/json" -d '{"guid": "the-app-guid","version": "0.0.0","ports" : [8080],"lifecycle": {"docker_lifecycle": {"image": "busybox","command": ["/bin/sleep", "100"]}},"instances": 1}'

  echo "Checking if app exists..."
  kubectl -n eirini-workloads get pods | grep the-app-guid
  echo "SUCCESS"
}

# test_crd() {
#   kubectl apply -f <<-yamlhere
# lrp yaml goes here
# yamlhere
#   kubectl -n eirini-workloads get pods | grep the-app-guid
# }

echo "Cleaning up..."
kubectl -n eirini-workloads delete statefulsets --all

test_api

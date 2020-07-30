# Deploy without Helm

- Create prerequisites (TODO: What are those?)
- kubectl apply the yaml files
- Testing? (e.g. call some script that curls Eirini)


# Prerequisites

- Create the namespace where you are going to deploy Eirini:

  ```kubectl create namespace eirini-core```

- In order to talk to the OPI component in a secure way (over SSL), you need to provide a Kubernetes secret that has the following keys:

  - tls.crt
  - tls.key
  - tls.ca

  This secret should be named: eirini-tls and it should be created in the namespace you created on the previous step (`eirini-core`).

  You can use the `deploy/helpers/generate_eirini_tls.sh` script to generate a self signed cert to get you going.

- Now you can create the Eirini ojbects by running the following command from the root directory of this repository:

  ```cat deploy/**/*.yml | kubectl apply -f -```

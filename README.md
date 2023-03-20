These instructions go over the instructions for deploying OPA, creating simple policies and then evaluating the using the OPA REST API.

## Pre-requisites

In order to deploy this demo you will need the following:

* __OpenShift Cluster.__ For this demo we use OCP 4.12, however any 4.x version should work as well. Alternatively you can use any Kubernetes cluster, however the instructions in this demo are specific to OpenShift.
* __OpenShift CLI.__ You can download OC cli from your cluster as specified here.
* __Git Bash or shell/bash terminal.__ Although not required, the commands below assume a Linux shell syntax.

## Deploying OPA

In order to deploy OPA as a REST API we first need to create 3 simple Kubernetes resources.

### Step 1: Create Kubernetes definition files

Create a file named deployment.yaml with this content:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: opa
spec:
  replicas: 1
  selector:
    matchLabels:
      app: opa
  template:
    metadata:
      labels:
        app: opa
    spec:
      containers:
        - name: opa
          securityContext:
            capabilities:
              drop: ["ALL"]
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            seccompProfile:
              type: "RuntimeDefault"
          image: openpolicyagent/opa:0.50.1-debug
          args:
            - "run"
            - "--watch"
            - "--ignore=.*"
            - "--server"
            - "--skip-version-check"
            - "--log-level"
            - "debug"
            - "--set=status.console=true"
            - "--set=decision_logs.console=true"
```

Most of the parameters above are optional, but included for higher verbosity level which is helpful for troubleshooting. You can view the purpose of these parameters in the documentation for the opa run command. Some important observations to highlight here are:

We are using OPA version `0.50.1` which was the latest available at the time of writing. We are using the `-debug` version of the OPA image which includes a CLI that can be useful for inspecting the deployed files. However for a production release it is recommended that you use the "-rootless" version of this image.

The `--server` parameter is what tells OPA to run in server mode so that it can listen for REST API requests.

Next create a file named "service.yaml" which will expose OPA as a service within the cluster:

```yaml
kind: Service
apiVersion: v1
metadata:
  labels:
    app: opa
  name: opa
spec:
  selector:
    app: opa
  ports:
  - name: http
    protocol: TCP
    port: 80
    targetPort: 8181
```

Finally create a file named "route.yaml" which will expose OPA service:

```
kind: Route
apiVersion: route.openshift.io/v1
metadata:
  labels:
    app: opa
  name: opa
spec:
  selector:
    matchLabels:
      app: opa
  to:
    kind: Service
    name: opa
  port:
    targetPort: http
```

Note that we are using http for demo purposes. In a production environment ensure that you are using https.

### Step 2: Deploy Kubernetes resources to OpenShift Cluster

First login to your OpenShift cluster by obtaining a token from your cluster using the OC CLI:

```bash
oc login --token=<sha256~token> --server=<your-openshift-cluster-api-url>
```

Next create a new project for this cluster. We export the NAMESPACE name as a variable so that it can be used in subsequent steps:

```bash
NAMESPACE=opa
oc new-project $NAMESPACE
```

New proceed to create the resources using the files created above:

```bash
oc apply -f deployment.yaml -n $NAMESPACE
oc apply -f service.yaml -n $NAMESPACE
oc apply -f route.yaml -n $NAMESPACE
```

To get the route that was created, issue the following command:

```bash
echo http://$(oc get route $NAMESPACE -o jsonpath='{.spec.host}')
```

Navigate to the route below in your browser and you should see the OPA home screen, which allows you to evaluate a policy


## Policy Evaluation Demo

Next we need to define and load a couple policies for demo purposes.

### Step 1: Create common JWT policy

One of the nice features about Rego is that it provides several built-in functions. One set of functions that is particularly helpful is the one for JWT (JSON Web Token) token validation. The policy shown below will first decode a JWT token and then validate it against a secret that was used to sign the token. We use a "shared" secret for demo purposes, however the JWT function can verify token using JWKS (JSON Web Key Sets). For anybody familiar with the JWKS verification flow knows that it is not a trivial implementation. The built-in verify token functions will take care of retrieving KIDs (Key ids) from the corresponding well known url and it even provides caching capabilities to speed up that process.

First create a file named jwt.rego:

```
package com.demo.common.jwt

import input
import future.keywords.in

valid_token(jwt) = token {
    [header, payload, sig]:= io.jwt.decode(jwt)

    valid := io.jwt.verify_hs256(jwt, 'secret')
    token := {"valid": valid,
                "name": payload.name}
}
```

As you can see from this rego file, it is primarily json, except for the import/package headers. Again, in this case we are using a shared secret, which is done only for demo purposes.

We will then load this policy using the "Create Policy" REST API from OPA Agent:

```bash
OPA_URL=http://$(oc get route $NAMESPACE -o jsonpath='{.spec.host}')
cat jwt.rego | curl --location --request PUT "${OPA_URL}/v1/policies/com/demo/common/jwt" --header 'Content-Type: text/plain' --data-binary '@-'
```

Let us decompose the url used above:

* `${OPA_URL}` - the base OPA URL
* `v1/policies` - the default location for policies
* `com/demo/common/jwt` - this is how policies are retrieved. Noticed that it matches the package name, i.e. `com.demo.common.jwt`, but using a different character separator. There is no hard rule that these should match, but I have found it as a good practice to follow to make it easier to organize policies.

### Step 2: Create API Authorization policy

In this step we create a policy that uses the common JWT policy loaded above. Create a file named api.rego with this content:

```
package com.demo.myapi

import data.com.demo.common.jwt.valid_token

default allow := { #disallow requests by default
    "allowed": false,
    "reason": "unauthorized resource access"
}

allow := { "allowed": true } { #allow GET requests to viewer user
    input.method == "GET"
    input.path[1] == "policy"
    token := valid_token(input.identity)
    token.name == "viewer"
    token.valid
}

allow := { "allowed": true } { #allow POST requests to admin user 
    input.method == "POST"
    input.path[1] == "policy"
    token := valid_token(input.identity)
    token.name == "admin"
    token.valid
}
```

Notice the import to the "valid_token" function. It matches the package used above, but it is prepended with data.

Next we load this policy with a similar curl command:

```bash
cat api.rego | curl --location --request PUT "${OPA_URL}/v1/policies/com/demo/myapi" \
--header 'Content-Type: application/json' --data-binary '@-'
``` 

### Step 3: Evaluate policy

To evaluate the policy we will need to get a valid jwt token. You can get one from jwt.io, the only requirement is that you enter the same secret from the jwt policy above into the `<your-256-bit-secret>` on the "Verify Signature" section. Additionally change the name (in the Payload section) to viewer and copy the generated token. Subsequently repeat the steps and enter admin as the name and save both tokens in a file where you can copy values from.

Next create a request to test a successful viewer request named viewer-allowed.json:

```
{
    "input": {
        "identity": "<viewer token>",
        "path": "policy",
        "method": "GET"
    }
}
```

Execute the curl command below (notice the url changes from policy to data):

```
cat viewer-not-allowed.json | curl --location --request POST "${OPA_URL}/v1/data/com/demo/myapi" --header 'Content-Type: application/json' --data-binary '@-'
```

Expect allowed true output similar to this:

```json
{
    "result": {
        "allow": {
            "allowed": true
        }
    }
}
```

Next create a request to test a not allowed viewer request named viewer-not-allowed.json by changing the method to POST:

```
{
    "input": {
        "identity": "<viewer token>",
        "path": "policy",
        "method": "POST"
    }
}
```

Execute the curl command below and expect the output to include allowed false:

```
cat viewer-not-allowed.json | curl --location --request POST "${OPA_URL}/v1/data/com/demo/myapi" \
--header 'Content-Type: application/json' --data-binary '@-'

{"result":{"allow":{"allowed":false,"reason":"unauthorized resource access"}}
```

Next create an admin-allowed.json file with this request:

```json
{
    "input": {
        "identity": "<admin jwt token>",
        "path": "policy",
        "method": "POST"
    }
}
```

Execute the curl command and expect the output to include allowed true:

```
cat admin-allowed.json | curl --location --request POST "${OPA_URL}/v1/data/com/demo/myapi" \
--header 'Content-Type: application/json' --data-binary '@-'
```

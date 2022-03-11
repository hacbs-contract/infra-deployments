#!/bin/bash

source $(dirname $0)/_helpers.sh
set -ue

# Use a specific taskrun if provided, otherwise use the latest
TASKRUN_NAME=taskrun/${1:-$( tkn-last-taskrun kaniko-chains )}

# Let's not hard code the image url or the registry
IMAGE_URL=$( oc get $TASKRUN_NAME -o json | jq -r '.status.taskResults[1].value' )
IMAGE_REGISTRY=$( echo $IMAGE_URL | cut -d/ -f1 )
#IMAGE_REGISTRY=$( oc registry info )
IS_REGISTRY_INTERNAL=$([[ $IMAGE_REGISTRY = image-registry.openshift-image-registry.svc* ]] && echo true)

SIG_KEY="k8s://tekton-chains/signing-secrets"

title "Inspect $TASKRUN_NAME annotations"
# Just want to show the chains related fields
oc get $TASKRUN_NAME -o yaml | yq-pretty .metadata.annotations
pause

title "Image url from task result"
kubectl get $TASKRUN_NAME -o jsonpath="{.status.taskResults[?(@.name == \"IMAGE_URL\")].value}"

title "Image digest from task result"
kubectl get $TASKRUN_NAME -o jsonpath="{.status.taskResults[?(@.name == \"IMAGE_DIGEST\")].value}"
echo

if $IS_REGISTRY_INTERNAL; then
  oc create -f "$HACK_CHAINS/cosign-verify-tasks.yaml" 2>&1 | grep -q 'already exists' && oc replace -f "$HACK_CHAINS/cosign-verify-tasks.yaml"
fi

title "Cosign verify the image"
if $IS_REGISTRY_INTERNAL; then
  show-then-run tkn clustertask start cosign-verify -p IMAGE=$IMAGE_URL --use-param-defaults --showlog
  tkn taskrun describe -o=go-template='{{range .status.taskResults}}{{if eq .name "VERIFY_JSON"}}{{.value}}{{end}}{{end}}' $(tkn-last-taskrun cosign-verify) > /tmp/verify.out
else
  title "Make sure we're logged in to the registry"
  # Make sure we have a docker credential since cosign will need it
  # (Todo: Probably shouldn't assume kubeadmin user here)
  oc whoami -t | docker login -u kubeadmin --password-stdin $IMAGE_REGISTRY

  # Save the output data to a file so we can look at it later
  # (Actually we could just pipe it to jq because the text goes to stderr I think..?)
  show-then-run "cosign verify --key $SIG_KEY $IMAGE_URL --output-file /tmp/verify.out"
fi
yq e -P /tmp/verify.out
pause

title "Cosign verify the image's attestation"
if $IS_REGISTRY_INTERNAL; then
  show-then-run tkn clustertask start cosign-verify-attestation -p IMAGE=$IMAGE_URL --use-param-defaults --showlog
  tkn taskrun describe -o=go-template='{{range .status.taskResults}}{{if eq .name "VERIFY_JSON"}}{{.value}}{{end}}{{end}}' $(tkn-last-taskrun cosign-verify-attestation) > /tmp/verify-att.out
else
  show-then-run "cosign verify-attestation --key $SIG_KEY $IMAGE_URL --output-file /tmp/verify-att.out"
fi
# There can be multiple attestations for some reason and hence multiple lines in
# this file, which makes it invalid json. For the sake of the demo we'll ignore
# all but the last line.
tail -1 /tmp/verify-att.out | yq e . -P -
pause

title "Inspect the payload from that attestation output"
tail -1 /tmp/verify-att.out | yq e .payload - | base64 -d | yq e . -P -

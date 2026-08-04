#!/usr/bin/env bash
# SEC-080: wildcard verbs on secrets plus escalate/bind grants.
FIXTURE_NAME="sec-080-wildcard-rbac"
source "$(dirname "$0")/common.sh"
init_repo
write_file config/rbac/role.yaml <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kserve-manager-role
rules:
  - apiGroups: ["serving.kserve.io"]
    resources: ["llminferenceservices"]
    verbs: ["get", "list", "watch", "update", "patch"]
YAML
commit "initial manager role"
write_file config/rbac/role.yaml <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kserve-manager-role
rules:
  - apiGroups: ["serving.kserve.io"]
    resources: ["llminferenceservices"]
    verbs: ["get", "list", "watch", "update", "patch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["*"]
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["clusterroles", "clusterrolebindings"]
    verbs: ["escalate", "bind", "create"]
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["get", "list"]
YAML
commit "grant manager access to secrets and rbac"
emit_repo

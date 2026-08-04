#!/usr/bin/env bash
# Precision: logging a Secret's name/namespace and a storage KEY NAME is not a leak.
# StorageKey is the name of a key inside the storage-config Secret, not the credential.
# Must NOT be flagged as SEC-110.
FIXTURE_NAME="negative-sec-110-secret-name"
source "$(dirname "$0")/common.sh"
init_repo
write_file pkg/controller/v1alpha1/localmodelnode/storage.go <<'GO'
package localmodelnode

import (
	"context"

	"sigs.k8s.io/controller-runtime/pkg/log"
)

func resolveStorage(ctx context.Context) error {
	return nil
}
GO
commit "initial storage resolution"
write_file pkg/controller/v1alpha1/localmodelnode/storage.go <<'GO'
package localmodelnode

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/klog/v2"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

func resolveStorage(ctx context.Context, modelInfo *ModelInfo, secret *corev1.Secret) error {
	// Identifiers only: the secret's name/namespace and the NAME of the key to read.
	log.FromContext(ctx).Info("injecting storage spec credentials",
		"secret", klog.KObj(secret),
		"storageKey", *modelInfo.Storage.StorageKey,
		"serviceAccountName", modelInfo.ServiceAccountName,
	)

	if _, ok := secret.Data[*modelInfo.Storage.StorageKey]; !ok {
		return fmt.Errorf("secret %s/%s has no key %q",
			secret.Namespace, secret.Name, *modelInfo.Storage.StorageKey)
	}
	return nil
}
GO
commit "log storage key name when resolving credentials"
emit_repo

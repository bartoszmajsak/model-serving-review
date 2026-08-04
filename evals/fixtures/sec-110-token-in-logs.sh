#!/usr/bin/env bash
# SEC-110: decoded token value written to logs and wrapped into an error.
FIXTURE_NAME="sec-110-token-in-logs"
source "$(dirname "$0")/common.sh"
init_repo
write_file pkg/controller/v1alpha1/localmodelnode/credentials.go <<'GO'
package localmodelnode

import (
	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

func injectCredentials(ctx context.Context, secret *corev1.Secret) error {
	log.FromContext(ctx).Info("injecting credentials", "secret", secret.Name)
	return nil
}
GO
commit "initial credential injection"
write_file pkg/controller/v1alpha1/localmodelnode/credentials.go <<'GO'
package localmodelnode

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

func injectCredentials(ctx context.Context, secret *corev1.Secret) error {
	token := string(secret.Data["HF_TOKEN"])

	log.FromContext(ctx).Info("injecting credentials",
		"secret", secret.Name,
		"token", token,
	)

	log.FromContext(ctx).V(2).Info("full storage secret", "secret", secret)

	if err := validateToken(token); err != nil {
		return fmt.Errorf("token %s rejected by registry: %w", token, err)
	}
	return nil
}
GO
commit "log token during credential injection for debugging"
emit_repo

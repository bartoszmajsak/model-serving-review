#!/usr/bin/env bash
FIXTURE_NAME="sync-060-missing-default-companion"
source "$(dirname "$0")/common.sh"
init_repo "https://github.com/opendatahub-io/kserve.git"

write_file pkg/controller/v1alpha2/llmisvc/controller.go <<'GO'
package llmisvc

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

type LLMISVCReconciler struct{}

func (r *LLMISVCReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	return ctrl.Result{}, nil
}
GO
commit "initial llmisvc controller"

write_file pkg/controller/v1alpha2/llmisvc/controller.go <<'GO'
package llmisvc

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

type LLMISVCReconciler struct{}

func (r *LLMISVCReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	if err := r.configureIngress(ctx, req); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}
GO

write_file pkg/controller/v1alpha2/llmisvc/router_odh.go <<'GO'
//go:build distro

package llmisvc

import (
	"context"

	routev1 "github.com/openshift/api/route/v1"
	ctrl "sigs.k8s.io/controller-runtime"
)

func (r *LLMISVCReconciler) configureIngress(ctx context.Context, req ctrl.Request) error {
	route := &routev1.Route{}
	_ = route
	return nil
}
GO
commit "add ODH ingress hook"

emit_repo

#!/usr/bin/env bash
# Routing regression: a diff touching only internal/controller/ must reach controller-reviewer.
# Before controller_files existed, controller.diff filtered pkg/controller/ and cmd/ only, so this
# diff produced an empty controller.diff even though internal/controller/ is documented as in scope.
# The planted violation is CTL-010 (deep nesting) so the fixture also proves the agent actually ran.
FIXTURE_NAME="routing-internal-controller"
source "$(dirname "$0")/common.sh"

init_repo

write_file internal/controller/gateway_controller.go <<'GO'
package controller

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

func (r *GatewayReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	gw, err := r.getGateway(ctx, req)
	if err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, r.reconcileGateway(ctx, gw)
}
GO

commit "initial gateway controller"

write_file internal/controller/gateway_controller.go <<'GO'
package controller

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

func (r *GatewayReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	gw, err := r.getGateway(ctx, req)
	if err != nil {
		return ctrl.Result{}, err
	}

	if gw != nil {
		if gw.Spec.Listeners != nil {
			if len(gw.Spec.Listeners) > 0 {
				if gw.Spec.Listeners[0].TLS != nil {
					if gw.Spec.Listeners[0].TLS.Mode != nil {
						if err := r.reconcileTLS(ctx, gw); err != nil {
							return ctrl.Result{}, err
						}
					}
				}
			}
		}
	}

	return ctrl.Result{}, r.reconcileGateway(ctx, gw)
}
GO

commit "add TLS listener handling"

emit_repo

#!/usr/bin/env bash
# CTL-150: finalizer removal gated behind cleanup that errors when the resource is already gone.
FIXTURE_NAME="ctl-150-stuck-finalizer"
source "$(dirname "$0")/common.sh"
init_repo
write_file pkg/controller/llmisvc/controller.go <<'GO'
package llmisvc

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	llmSvc, err := r.get(ctx, req)
	if err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, r.reconcile(ctx, llmSvc)
}
GO
commit "initial controller"
write_file pkg/controller/llmisvc/controller.go <<'GO'
package llmisvc

import (
	"context"
	"fmt"

	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

const finalizerName = "llminferenceservice.kserve.io/finalizer"

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	llmSvc, err := r.get(ctx, req)
	if err != nil {
		return ctrl.Result{}, err
	}

	if llmSvc.DeletionTimestamp.IsZero() {
		if !controllerutil.ContainsFinalizer(llmSvc, finalizerName) {
			controllerutil.AddFinalizer(llmSvc, finalizerName)
			if err := r.Update(ctx, llmSvc); err != nil {
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{}, r.reconcile(ctx, llmSvc)
	}

	// Deletion path: tear down the managed gateway route before releasing the object.
	route := &HTTPRoute{}
	if err := r.Get(ctx, routeKey(llmSvc), route); err != nil {
		return ctrl.Result{}, fmt.Errorf("getting managed route: %w", err)
	}
	if err := r.Delete(ctx, route); err != nil {
		return ctrl.Result{}, fmt.Errorf("deleting managed route: %w", err)
	}

	controllerutil.RemoveFinalizer(llmSvc, finalizerName)
	return ctrl.Result{}, r.Update(ctx, llmSvc)
}
GO
commit "add finalizer to clean up managed route on deletion"
emit_repo

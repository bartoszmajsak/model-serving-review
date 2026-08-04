#!/usr/bin/env bash
# Precision: a correct finalizer lifecycle must not be flagged as CTL-150.
# Cleanup tolerates IsNotFound and the finalizer is removed unconditionally afterwards.
FIXTURE_NAME="negative-ctl-150-clean-finalizer"
source "$(dirname "$0")/common.sh"
init_repo
write_file pkg/controller/llmisvc/lifecycle.go <<'GO'
package llmisvc

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	return ctrl.Result{}, nil
}
GO
commit "initial lifecycle"
write_file pkg/controller/llmisvc/lifecycle.go <<'GO'
package llmisvc

import (
	"context"
	"fmt"

	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

const finalizerName = "llminferenceservice.kserve.io/finalizer"

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	llmSvc, err := r.get(ctx, req)
	if err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	if !llmSvc.DeletionTimestamp.IsZero() {
		return ctrl.Result{}, r.finalize(ctx, llmSvc)
	}

	if controllerutil.AddFinalizer(llmSvc, finalizerName) {
		if err := r.Update(ctx, llmSvc); err != nil {
			return ctrl.Result{}, fmt.Errorf("adding finalizer: %w", err)
		}
	}
	return ctrl.Result{}, r.reconcile(ctx, llmSvc)
}

// finalize releases external state. Cleanup is idempotent: an already-deleted
// route is success, so the finalizer is always removed and deletion completes.
func (r *Reconciler) finalize(ctx context.Context, llmSvc *LLMInferenceService) error {
	if !controllerutil.ContainsFinalizer(llmSvc, finalizerName) {
		return nil
	}

	route := &HTTPRoute{}
	if err := r.Get(ctx, routeKey(llmSvc), route); client.IgnoreNotFound(err) != nil {
		return fmt.Errorf("getting managed route: %w", err)
	} else if err == nil {
		if err := r.Delete(ctx, route); client.IgnoreNotFound(err) != nil {
			return fmt.Errorf("deleting managed route: %w", err)
		}
	}

	controllerutil.RemoveFinalizer(llmSvc, finalizerName)
	return r.Update(ctx, llmSvc)
}
GO
commit "add finalizer with idempotent route cleanup"
emit_repo

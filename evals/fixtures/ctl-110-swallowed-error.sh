#!/usr/bin/env bash
# CTL-110: reconcile failure replaced with a successful timed requeue.
FIXTURE_NAME="ctl-110-swallowed-error"
source "$(dirname "$0")/common.sh"
init_repo
write_file pkg/controller/llmisvc/router.go <<'GO'
package llmisvc

import (
	"context"
	"fmt"

	ctrl "sigs.k8s.io/controller-runtime"
)

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	llmSvc, err := r.get(ctx, req)
	if err != nil {
		return ctrl.Result{}, err
	}
	if err := r.reconcileRouter(ctx, llmSvc); err != nil {
		return ctrl.Result{}, fmt.Errorf("reconciling router: %w", err)
	}
	return ctrl.Result{}, nil
}
GO
commit "initial router reconcile"
write_file pkg/controller/llmisvc/router.go <<'GO'
package llmisvc

import (
	"context"
	"time"

	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/log"
)

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	llmSvc, err := r.get(ctx, req)
	if err != nil {
		return ctrl.Result{}, err
	}
	if err := r.reconcileRouter(ctx, llmSvc); err != nil {
		log.FromContext(ctx).Error(err, "router reconcile failed, will retry")
		return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
	}
	if err := r.reconcileScheduler(ctx, llmSvc); err != nil {
		log.FromContext(ctx).Error(err, "scheduler reconcile failed, will retry")
		return ctrl.Result{Requeue: true}, nil
	}
	return ctrl.Result{}, nil
}
GO
commit "retry router and scheduler failures instead of erroring"
emit_repo

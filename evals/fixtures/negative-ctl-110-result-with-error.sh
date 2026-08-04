#!/usr/bin/env bash
# Precision: `return result, err` with a non-nil error is redundant, not a CTL-110 violation.
# controller-runtime ignores ctrl.Result entirely when err != nil, so backoff is NOT bypassed.
# Also includes a cached client.List with no Limit, which must not be flagged as CTL-120.
FIXTURE_NAME="negative-ctl-110-result-with-error"
source "$(dirname "$0")/common.sh"
init_repo
write_file pkg/controller/llmisvc/scheduler.go <<'GO'
package llmisvc

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	return ctrl.Result{}, nil
}
GO
commit "initial scheduler reconcile"
write_file pkg/controller/llmisvc/scheduler.go <<'GO'
package llmisvc

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	llmSvc, err := r.get(ctx, req)
	if err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	// Cache-backed List scoped to one namespace by owner label. The informer cache
	// serves this read; it does not hit the API server and does not need pagination.
	var pods corev1.PodList
	if err := r.List(ctx, &pods,
		client.InNamespace(llmSvc.Namespace),
		client.MatchingLabels{"app.kubernetes.io/part-of": llmSvc.Name},
	); err != nil {
		return ctrl.Result{}, fmt.Errorf("listing engine pods: %w", err)
	}

	if err := r.reconcileScheduler(ctx, llmSvc, pods.Items); err != nil {
		// Redundant Requeue, but harmless: the result is ignored when err != nil.
		return ctrl.Result{Requeue: true}, fmt.Errorf("reconciling scheduler: %w", err)
	}
	return ctrl.Result{}, nil
}
GO
commit "reconcile scheduler from cached pod list"
emit_repo

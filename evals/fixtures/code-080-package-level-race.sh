#!/usr/bin/env bash
# CODE-080: package-level namespace variable written from Reconcile, os.Getenv per call.
FIXTURE_NAME="code-080-package-level-race"
source "$(dirname "$0")/common.sh"
init_repo
write_file internal/controller/servingruntime_controller.go <<'GO'
package controller

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

type ServingRuntimeReconciler struct {
	ControllerNamespace string
}

func (r *ServingRuntimeReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	_ = r.ControllerNamespace
	return ctrl.Result{}, nil
}
GO
commit "serving runtime reconciler"
write_file internal/controller/servingruntime_controller.go <<'GO'
package controller

import (
	"context"
	"os"

	ctrl "sigs.k8s.io/controller-runtime"
)

// controllerNamespace is resolved lazily on first reconcile.
var controllerNamespace string

var monitoringNamespaceCache = map[string]string{}

type ServingRuntimeReconciler struct{}

func (r *ServingRuntimeReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	if controllerNamespace == "" {
		controllerNamespace = os.Getenv("POD_NAMESPACE")
	}
	monitoringNamespaceCache[req.Namespace] = os.Getenv("MONITORING_NAMESPACE")
	return ctrl.Result{}, nil
}
GO
commit "resolve controller namespace from the environment"
emit_repo

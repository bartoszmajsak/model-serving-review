#!/usr/bin/env bash
# Negative CODE-080: namespaces injected at construction, and the one shared
# cache is guarded on both the read and the write path.
FIXTURE_NAME="negative-code-080-injected-config"
source "$(dirname "$0")/common.sh"
init_repo
write_file internal/controller/servingruntime_controller.go <<'GO'
package controller

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

type ServingRuntimeReconciler struct{}

func (r *ServingRuntimeReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	return ctrl.Result{}, nil
}
GO
commit "serving runtime reconciler"
write_file internal/controller/servingruntime_controller.go <<'GO'
package controller

import (
	"context"
	"sync"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
)

// defaultRuntimes is assigned at declaration and only read afterwards.
var defaultRuntimes = []string{"vllm-runtime", "tgis-runtime"}

var (
	gvResourcesMu    sync.RWMutex
	gvResourcesCache = map[string]*metav1.APIResourceList{}
)

type ServingRuntimeReconciler struct {
	ControllerNamespace string
	MonitoringNamespace string
}

func (r *ServingRuntimeReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	_ = r.ControllerNamespace
	_ = r.MonitoringNamespace
	_ = defaultRuntimes
	return ctrl.Result{}, nil
}

func (r *ServingRuntimeReconciler) resourcesFor(gv string) *metav1.APIResourceList {
	gvResourcesMu.RLock()
	cached, ok := gvResourcesCache[gv]
	gvResourcesMu.RUnlock()
	if ok {
		return cached
	}

	gvResourcesMu.Lock()
	defer gvResourcesMu.Unlock()
	if cached, ok := gvResourcesCache[gv]; ok {
		return cached
	}
	list := &metav1.APIResourceList{GroupVersion: gv}
	gvResourcesCache[gv] = list
	return list
}
GO
commit "inject namespaces at construction, guard the discovery cache"
emit_repo

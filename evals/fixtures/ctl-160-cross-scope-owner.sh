#!/usr/bin/env bash
# CTL-160: namespaced InferenceService set as owner of a cluster-scoped ClusterRoleBinding,
# plus an Owns() on a cluster-scoped type that can never fire.
FIXTURE_NAME="ctl-160-cross-scope-owner"
source "$(dirname "$0")/common.sh"
init_repo
write_file internal/controller/isvc_rbac.go <<'GO'
package controller

import (
	"context"

	rbacv1 "k8s.io/api/rbac/v1"
	kservev1beta1 "github.com/kserve/kserve/pkg/apis/serving/v1beta1"
)

func (r *InferenceServiceReconciler) reconcileRBAC(ctx context.Context, isvc *kservev1beta1.InferenceService) error {
	return nil
}
GO
commit "rbac reconciler stub"
write_file internal/controller/isvc_rbac.go <<'GO'
package controller

import (
	"context"

	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	kservev1beta1 "github.com/kserve/kserve/pkg/apis/serving/v1beta1"
)

func (r *InferenceServiceReconciler) reconcileRBAC(ctx context.Context, isvc *kservev1beta1.InferenceService) error {
	crb := &rbacv1.ClusterRoleBinding{
		ObjectMeta: metav1.ObjectMeta{Name: isvc.Namespace + "-" + isvc.Name + "-view"},
		RoleRef:    rbacv1.RoleRef{Kind: "ClusterRole", Name: "kserve-view"},
	}
	// Tie the binding's lifecycle to the InferenceService so it is cleaned up on delete.
	_ = controllerutil.SetControllerReference(isvc, crb, r.Scheme)
	return r.Create(ctx, crb)
}

func (r *InferenceServiceReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&kservev1beta1.InferenceService{}).
		Owns(&corev1.Namespace{}).
		Complete(r)
}
GO
commit "own the per-isvc ClusterRoleBinding and watch namespaces"
emit_repo

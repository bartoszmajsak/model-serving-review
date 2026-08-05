#!/usr/bin/env bash
# Negative CTL-160: same-namespace owner reference, and cluster-scoped children
# handled by a finalizer rather than by GC.
FIXTURE_NAME="negative-ctl-160-same-scope-owner"
source "$(dirname "$0")/common.sh"
init_repo
write_file internal/controller/isvc_rbac.go <<'GO'
package controller

import (
	"context"

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

	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"

	kservev1beta1 "github.com/kserve/kserve/pkg/apis/serving/v1beta1"
)

func (r *InferenceServiceReconciler) reconcileRBAC(ctx context.Context, isvc *kservev1beta1.InferenceService) error {
	// RoleBinding is namespaced and lives in the ISVC's own namespace, so GC handles it.
	rb := &rbacv1.RoleBinding{
		ObjectMeta: metav1.ObjectMeta{Name: isvc.Name + "-view", Namespace: isvc.Namespace},
		RoleRef:    rbacv1.RoleRef{Kind: "Role", Name: "kserve-view"},
	}
	if err := controllerutil.SetControllerReference(isvc, rb, r.Scheme); err != nil {
		return err
	}
	return r.Create(ctx, rb)
}

// cleanupClusterScoped removes the cluster-scoped binding, which cannot carry an
// owner reference to a namespaced InferenceService and so is never GC'd.
func (r *InferenceServiceReconciler) cleanupClusterScoped(ctx context.Context, isvc *kservev1beta1.InferenceService) error {
	crb := &rbacv1.ClusterRoleBinding{
		ObjectMeta: metav1.ObjectMeta{Name: isvc.Namespace + "-" + isvc.Name + "-view"},
	}
	return client.IgnoreNotFound(r.Delete(ctx, crb))
}
GO
commit "namespaced rolebinding via GC, cluster-scoped binding via explicit cleanup"
emit_repo

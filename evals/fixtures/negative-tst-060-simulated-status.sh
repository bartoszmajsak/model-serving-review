#!/usr/bin/env bash
FIXTURE_NAME="negative-tst-060-simulated-status"
source "$(dirname "$0")/common.sh"
init_repo

write_file pkg/controller/v1beta1/inferenceservice/controller_int_test.go <<'GO'
package inferenceservice

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("InferenceService controller", func() {
	It("creates a deployment", func() {
		isvc := makeISVC("basic")
		Expect(k8sClient.Create(ctx, isvc)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, isvc) })

		Eventually(func() error {
			return k8sClient.Get(ctx, deployKey(isvc), &appsv1.Deployment{})
		}, timeout, interval).Should(Succeed())
	})
})
GO
commit "initial controller integration test"

write_file pkg/controller/v1beta1/inferenceservice/controller_int_test.go <<'GO'
package inferenceservice

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	appsv1 "k8s.io/api/apps/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/rand"
	"k8s.io/client-go/util/retry"
	"k8s.io/utils/ptr"
)

var _ = Describe("InferenceService controller", func() {
	It("creates a deployment", func() {
		isvc := makeISVC("basic")
		Expect(k8sClient.Create(ctx, isvc)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, isvc) })

		Eventually(func() error {
			return k8sClient.Get(ctx, deployKey(isvc), &appsv1.Deployment{})
		}, timeout, interval).Should(Succeed())
	})

	It("reports readiness once the deployment reports available replicas", func() {
		cr := &rbacv1.ClusterRole{
			ObjectMeta: metav1.ObjectMeta{Name: "kserve-predictor-reader-" + rand.String(5)},
			Rules: []rbacv1.PolicyRule{{
				APIGroups: []string{""},
				Resources: []string{"configmaps"},
				Verbs:     []string{"get"},
			}},
		}
		Expect(k8sClient.Create(ctx, cr)).To(Succeed())
		DeferCleanup(func() { Expect(k8sClient.Delete(ctx, cr)).To(Succeed()) })

		isvc := makeISVC("ready")
		Expect(k8sClient.Create(ctx, isvc)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, isvc) })

		Expect(retry.RetryOnConflict(retry.DefaultRetry, func() error {
			if err := k8sClient.Get(ctx, isvcKey(isvc), isvc); err != nil {
				return err
			}
			isvc.Spec.Predictor.MinReplicas = ptr.To(int32(2))
			return k8sClient.Update(ctx, isvc)
		})).To(Succeed())

		// envtest runs no kubelet, so no Pod ever becomes ready and the Deployment
		// status is never populated. Simulate what kube-controller-manager would write.
		deploy := &appsv1.Deployment{}
		Eventually(func() error {
			return k8sClient.Get(ctx, deployKey(isvc), deploy)
		}, timeout, interval).Should(Succeed())
		deploy.Status.Replicas = 2
		deploy.Status.ReadyReplicas = 2
		deploy.Status.AvailableReplicas = 2
		Expect(k8sClient.Status().Update(ctx, deploy)).To(Succeed())

		Eventually(func() bool {
			Expect(k8sClient.Get(ctx, isvcKey(isvc), isvc)).To(Succeed())
			return isvc.Status.IsReady()
		}, timeout, interval).Should(BeTrue())
	})
})
GO
commit "add readiness integration test with simulated deployment status"

emit_repo

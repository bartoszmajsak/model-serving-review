#!/usr/bin/env bash
FIXTURE_NAME="tst-060-envtest-no-gc"
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
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	rbacv1 "k8s.io/api/rbac/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
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

	It("grants the predictor read access and reports readiness", func() {
		cr := &rbacv1.ClusterRole{
			ObjectMeta: metav1.ObjectMeta{Name: "kserve-predictor-reader"},
			Rules: []rbacv1.PolicyRule{{
				APIGroups: []string{""},
				Resources: []string{"configmaps"},
				Verbs:     []string{"get"},
			}},
		}
		Expect(k8sClient.Create(ctx, cr)).To(Succeed())

		isvc := makeISVC("ready")
		Expect(k8sClient.Create(ctx, isvc)).To(Succeed())

		time.Sleep(5 * time.Second)

		isvc.Spec.Predictor.MinReplicas = ptr.To(int32(2))
		Expect(k8sClient.Update(ctx, isvc)).To(Succeed())

		Eventually(func() bool {
			Expect(k8sClient.Get(ctx, isvcKey(isvc), isvc)).To(Succeed())
			return isvc.Status.IsReady()
		}, timeout, interval).Should(BeTrue())
	})

	It("cleans up the deployment when the service is deleted", func() {
		isvc := makeISVC("cascade")
		Expect(k8sClient.Create(ctx, isvc)).To(Succeed())
		Eventually(func() error {
			return k8sClient.Get(ctx, deployKey(isvc), &appsv1.Deployment{})
		}, timeout, interval).Should(Succeed())

		Expect(k8sClient.Delete(ctx, isvc)).To(Succeed())

		Eventually(func() bool {
			err := k8sClient.Get(ctx, deployKey(isvc), &appsv1.Deployment{})
			return apierrors.IsNotFound(err)
		}, timeout, interval).Should(BeTrue())
	})
})
GO
commit "add readiness and cascade deletion integration tests"

emit_repo

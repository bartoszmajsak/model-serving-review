#!/usr/bin/env bash
FIXTURE_NAME="api-080-required-empty-string"
source "$(dirname "$0")/common.sh"
init_repo

write_file pkg/apis/serving/v1alpha1/llm_storage_types.go <<'GO'
package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

type StorageSpec struct {
	// Path within the bucket.
	// +required
	// +kubebuilder:validation:MinLength=1
	Path string `json:"path"`
}

type LLMStorage struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              StorageSpec `json:"spec,omitempty"`
}
GO
commit "initial storage types"

write_file pkg/apis/serving/v1alpha1/llm_storage_types.go <<'GO'
package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

type StorageSpec struct {
	// Path within the bucket.
	// +required
	// +kubebuilder:validation:MinLength=1
	Path string `json:"path"`

	// BucketName is the object storage bucket holding the model. The controller
	// builds every download URL from it, so an empty value is not usable.
	// +required
	BucketName string `json:"bucketName"`

	// SecretRef names the credentials Secret. Must be resolvable.
	// +required
	SecretRef *string `json:"secretRef"`
}

type LLMStorage struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              StorageSpec `json:"spec,omitempty"`
}
GO
commit "add bucket and credential fields"

emit_repo

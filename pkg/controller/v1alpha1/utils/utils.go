/*
Copyright 2021 The KServe Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package utils

import (
	"context"

	"github.com/pkg/errors"
	operatorv1beta1 "knative.dev/operator/pkg/apis/operator/v1beta1"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/kserve/kserve/pkg/constants"

	corev1 "k8s.io/api/core/v1"
	corev1helpers "k8s.io/component-helpers/scheduling/corev1"
)

// GetAutoscalerConfiguration reads the global knative serving configuration and retrieves values related to the autoscaler.
// This configuration is defined in the knativeserving custom resource.
func GetAutoscalerConfiguration(ctx context.Context, client client.Client) (string, string, error) {
	// Set allow-zero-initial-scale and intitial-scale to their default values to start.
	// If autoscaling values are not set in the configuration, then the defaults are used.
	allowZeroInitialScale := "false"
	globalInitialScale := "1"

	// List all knativeserving custom resources to handle scenarios where the custom resource is not created in the default knative-serving namespace.
	knservingList := &operatorv1beta1.KnativeServingList{}
	err := client.List(ctx, knservingList)
	if err != nil {
		return allowZeroInitialScale, globalInitialScale, errors.Wrapf(
			err,
			"fails to retrieve the knativeserving custom resource.",
		)
	} else if len(knservingList.Items) == 0 {
		return allowZeroInitialScale, globalInitialScale, errors.New("no knativeserving resources found in cluster.")
	}

	// Always use the first knativeserving resource returned.
	// We are operating under the assumption that there should be a single knativeserving custom resource created on the cluster.
	knserving := knservingList.Items[0]

	// Check for both the autoscaler key with and without the 'config-' prefix. Both are supported by knative.
	var knservingAutoscalerConfig map[string]string
	if _, ok := knserving.Spec.Config[constants.AutoscalerKey]; ok {
		knservingAutoscalerConfig = knserving.Spec.Config[constants.AutoscalerKey]
	} else if _, ok := knserving.Spec.Config["config-"+constants.AutoscalerKey]; ok {
		knservingAutoscalerConfig = knserving.Spec.Config["config-"+constants.AutoscalerKey]
	}

	if configuredAllowZeroInitialScale, ok := knservingAutoscalerConfig[constants.AutoscalerAllowZeroScaleKey]; ok {
		allowZeroInitialScale = configuredAllowZeroInitialScale
	}
	if configuredInitialScale, ok := knservingAutoscalerConfig[constants.AutoscalerInitialScaleKey]; ok {
		globalInitialScale = configuredInitialScale
	}

	return allowZeroInitialScale, globalInitialScale, nil
}

// CheckNodeAffinity returns true if the node matches the node affinity specified in the PV Spec
func CheckNodeAffinity(pvSpec *corev1.PersistentVolumeSpec, node corev1.Node) (bool, error) {
	if pvSpec.NodeAffinity == nil || pvSpec.NodeAffinity.Required == nil {
		return false, nil
	}

	terms := pvSpec.NodeAffinity.Required
	return corev1helpers.MatchNodeSelectorTerms(&node, terms)
}

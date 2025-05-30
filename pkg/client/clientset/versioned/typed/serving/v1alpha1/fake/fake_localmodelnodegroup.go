/*
Copyright 2023 The KServe Authors.

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

// Code generated by client-gen. DO NOT EDIT.

package fake

import (
	v1alpha1 "github.com/kserve/kserve/pkg/apis/serving/v1alpha1"
	servingv1alpha1 "github.com/kserve/kserve/pkg/client/clientset/versioned/typed/serving/v1alpha1"
	gentype "k8s.io/client-go/gentype"
)

// fakeLocalModelNodeGroups implements LocalModelNodeGroupInterface
type fakeLocalModelNodeGroups struct {
	*gentype.FakeClientWithList[*v1alpha1.LocalModelNodeGroup, *v1alpha1.LocalModelNodeGroupList]
	Fake *FakeServingV1alpha1
}

func newFakeLocalModelNodeGroups(fake *FakeServingV1alpha1, namespace string) servingv1alpha1.LocalModelNodeGroupInterface {
	return &fakeLocalModelNodeGroups{
		gentype.NewFakeClientWithList[*v1alpha1.LocalModelNodeGroup, *v1alpha1.LocalModelNodeGroupList](
			fake.Fake,
			namespace,
			v1alpha1.SchemeGroupVersion.WithResource("localmodelnodegroups"),
			v1alpha1.SchemeGroupVersion.WithKind("LocalModelNodeGroup"),
			func() *v1alpha1.LocalModelNodeGroup { return &v1alpha1.LocalModelNodeGroup{} },
			func() *v1alpha1.LocalModelNodeGroupList { return &v1alpha1.LocalModelNodeGroupList{} },
			func(dst, src *v1alpha1.LocalModelNodeGroupList) { dst.ListMeta = src.ListMeta },
			func(list *v1alpha1.LocalModelNodeGroupList) []*v1alpha1.LocalModelNodeGroup {
				return gentype.ToPointerSlice(list.Items)
			},
			func(list *v1alpha1.LocalModelNodeGroupList, items []*v1alpha1.LocalModelNodeGroup) {
				list.Items = gentype.FromPointerSlice(items)
			},
		),
		fake,
	}
}

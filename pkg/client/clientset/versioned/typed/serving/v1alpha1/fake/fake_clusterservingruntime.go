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
	"context"

	v1alpha1 "github.com/kserve/kserve/pkg/apis/serving/v1alpha1"
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	labels "k8s.io/apimachinery/pkg/labels"
	types "k8s.io/apimachinery/pkg/types"
	watch "k8s.io/apimachinery/pkg/watch"
	testing "k8s.io/client-go/testing"
)

// FakeClusterServingRuntimes implements ClusterServingRuntimeInterface
type FakeClusterServingRuntimes struct {
	Fake *FakeServingV1alpha1
	ns   string
}

var clusterservingruntimesResource = v1alpha1.SchemeGroupVersion.WithResource("clusterservingruntimes")

var clusterservingruntimesKind = v1alpha1.SchemeGroupVersion.WithKind("ClusterServingRuntime")

// Get takes name of the clusterServingRuntime, and returns the corresponding clusterServingRuntime object, and an error if there is any.
func (c *FakeClusterServingRuntimes) Get(ctx context.Context, name string, options v1.GetOptions) (result *v1alpha1.ClusterServingRuntime, err error) {
	obj, err := c.Fake.
		Invokes(testing.NewGetAction(clusterservingruntimesResource, c.ns, name), &v1alpha1.ClusterServingRuntime{})

	if obj == nil {
		return nil, err
	}
	return obj.(*v1alpha1.ClusterServingRuntime), err
}

// List takes label and field selectors, and returns the list of ClusterServingRuntimes that match those selectors.
func (c *FakeClusterServingRuntimes) List(ctx context.Context, opts v1.ListOptions) (result *v1alpha1.ClusterServingRuntimeList, err error) {
	obj, err := c.Fake.
		Invokes(testing.NewListAction(clusterservingruntimesResource, clusterservingruntimesKind, c.ns, opts), &v1alpha1.ClusterServingRuntimeList{})

	if obj == nil {
		return nil, err
	}

	label, _, _ := testing.ExtractFromListOptions(opts)
	if label == nil {
		label = labels.Everything()
	}
	list := &v1alpha1.ClusterServingRuntimeList{ListMeta: obj.(*v1alpha1.ClusterServingRuntimeList).ListMeta}
	for _, item := range obj.(*v1alpha1.ClusterServingRuntimeList).Items {
		if label.Matches(labels.Set(item.Labels)) {
			list.Items = append(list.Items, item)
		}
	}
	return list, err
}

// Watch returns a watch.Interface that watches the requested clusterServingRuntimes.
func (c *FakeClusterServingRuntimes) Watch(ctx context.Context, opts v1.ListOptions) (watch.Interface, error) {
	return c.Fake.
		InvokesWatch(testing.NewWatchAction(clusterservingruntimesResource, c.ns, opts))

}

// Create takes the representation of a clusterServingRuntime and creates it.  Returns the server's representation of the clusterServingRuntime, and an error, if there is any.
func (c *FakeClusterServingRuntimes) Create(ctx context.Context, clusterServingRuntime *v1alpha1.ClusterServingRuntime, opts v1.CreateOptions) (result *v1alpha1.ClusterServingRuntime, err error) {
	obj, err := c.Fake.
		Invokes(testing.NewCreateAction(clusterservingruntimesResource, c.ns, clusterServingRuntime), &v1alpha1.ClusterServingRuntime{})

	if obj == nil {
		return nil, err
	}
	return obj.(*v1alpha1.ClusterServingRuntime), err
}

// Update takes the representation of a clusterServingRuntime and updates it. Returns the server's representation of the clusterServingRuntime, and an error, if there is any.
func (c *FakeClusterServingRuntimes) Update(ctx context.Context, clusterServingRuntime *v1alpha1.ClusterServingRuntime, opts v1.UpdateOptions) (result *v1alpha1.ClusterServingRuntime, err error) {
	obj, err := c.Fake.
		Invokes(testing.NewUpdateAction(clusterservingruntimesResource, c.ns, clusterServingRuntime), &v1alpha1.ClusterServingRuntime{})

	if obj == nil {
		return nil, err
	}
	return obj.(*v1alpha1.ClusterServingRuntime), err
}

// UpdateStatus was generated because the type contains a Status member.
// Add a +genclient:noStatus comment above the type to avoid generating UpdateStatus().
func (c *FakeClusterServingRuntimes) UpdateStatus(ctx context.Context, clusterServingRuntime *v1alpha1.ClusterServingRuntime, opts v1.UpdateOptions) (*v1alpha1.ClusterServingRuntime, error) {
	obj, err := c.Fake.
		Invokes(testing.NewUpdateSubresourceAction(clusterservingruntimesResource, "status", c.ns, clusterServingRuntime), &v1alpha1.ClusterServingRuntime{})

	if obj == nil {
		return nil, err
	}
	return obj.(*v1alpha1.ClusterServingRuntime), err
}

// Delete takes name of the clusterServingRuntime and deletes it. Returns an error if one occurs.
func (c *FakeClusterServingRuntimes) Delete(ctx context.Context, name string, opts v1.DeleteOptions) error {
	_, err := c.Fake.
		Invokes(testing.NewDeleteActionWithOptions(clusterservingruntimesResource, c.ns, name, opts), &v1alpha1.ClusterServingRuntime{})

	return err
}

// DeleteCollection deletes a collection of objects.
func (c *FakeClusterServingRuntimes) DeleteCollection(ctx context.Context, opts v1.DeleteOptions, listOpts v1.ListOptions) error {
	action := testing.NewDeleteCollectionAction(clusterservingruntimesResource, c.ns, listOpts)

	_, err := c.Fake.Invokes(action, &v1alpha1.ClusterServingRuntimeList{})
	return err
}

// Patch applies the patch and returns the patched clusterServingRuntime.
func (c *FakeClusterServingRuntimes) Patch(ctx context.Context, name string, pt types.PatchType, data []byte, opts v1.PatchOptions, subresources ...string) (result *v1alpha1.ClusterServingRuntime, err error) {
	obj, err := c.Fake.
		Invokes(testing.NewPatchSubresourceAction(clusterservingruntimesResource, c.ns, name, pt, data, subresources...), &v1alpha1.ClusterServingRuntime{})

	if obj == nil {
		return nil, err
	}
	return obj.(*v1alpha1.ClusterServingRuntime), err
}
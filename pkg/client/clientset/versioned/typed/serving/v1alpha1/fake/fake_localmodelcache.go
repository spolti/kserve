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

// FakeLocalModelCaches implements LocalModelCacheInterface
type FakeLocalModelCaches struct {
	Fake *FakeServingV1alpha1
	ns   string
}

var localmodelcachesResource = v1alpha1.SchemeGroupVersion.WithResource("localmodelcaches")

var localmodelcachesKind = v1alpha1.SchemeGroupVersion.WithKind("LocalModelCache")

// Get takes name of the localModelCache, and returns the corresponding localModelCache object, and an error if there is any.
func (c *FakeLocalModelCaches) Get(ctx context.Context, name string, options v1.GetOptions) (result *v1alpha1.LocalModelCache, err error) {
	emptyResult := &v1alpha1.LocalModelCache{}
	obj, err := c.Fake.
		Invokes(testing.NewGetActionWithOptions(localmodelcachesResource, c.ns, name, options), emptyResult)

	if obj == nil {
		return emptyResult, err
	}
	return obj.(*v1alpha1.LocalModelCache), err
}

// List takes label and field selectors, and returns the list of LocalModelCaches that match those selectors.
func (c *FakeLocalModelCaches) List(ctx context.Context, opts v1.ListOptions) (result *v1alpha1.LocalModelCacheList, err error) {
	emptyResult := &v1alpha1.LocalModelCacheList{}
	obj, err := c.Fake.
		Invokes(testing.NewListActionWithOptions(localmodelcachesResource, localmodelcachesKind, c.ns, opts), emptyResult)

	if obj == nil {
		return emptyResult, err
	}

	label, _, _ := testing.ExtractFromListOptions(opts)
	if label == nil {
		label = labels.Everything()
	}
	list := &v1alpha1.LocalModelCacheList{ListMeta: obj.(*v1alpha1.LocalModelCacheList).ListMeta}
	for _, item := range obj.(*v1alpha1.LocalModelCacheList).Items {
		if label.Matches(labels.Set(item.Labels)) {
			list.Items = append(list.Items, item)
		}
	}
	return list, err
}

// Watch returns a watch.Interface that watches the requested localModelCaches.
func (c *FakeLocalModelCaches) Watch(ctx context.Context, opts v1.ListOptions) (watch.Interface, error) {
	return c.Fake.
		InvokesWatch(testing.NewWatchActionWithOptions(localmodelcachesResource, c.ns, opts))

}

// Create takes the representation of a localModelCache and creates it.  Returns the server's representation of the localModelCache, and an error, if there is any.
func (c *FakeLocalModelCaches) Create(ctx context.Context, localModelCache *v1alpha1.LocalModelCache, opts v1.CreateOptions) (result *v1alpha1.LocalModelCache, err error) {
	emptyResult := &v1alpha1.LocalModelCache{}
	obj, err := c.Fake.
		Invokes(testing.NewCreateActionWithOptions(localmodelcachesResource, c.ns, localModelCache, opts), emptyResult)

	if obj == nil {
		return emptyResult, err
	}
	return obj.(*v1alpha1.LocalModelCache), err
}

// Update takes the representation of a localModelCache and updates it. Returns the server's representation of the localModelCache, and an error, if there is any.
func (c *FakeLocalModelCaches) Update(ctx context.Context, localModelCache *v1alpha1.LocalModelCache, opts v1.UpdateOptions) (result *v1alpha1.LocalModelCache, err error) {
	emptyResult := &v1alpha1.LocalModelCache{}
	obj, err := c.Fake.
		Invokes(testing.NewUpdateActionWithOptions(localmodelcachesResource, c.ns, localModelCache, opts), emptyResult)

	if obj == nil {
		return emptyResult, err
	}
	return obj.(*v1alpha1.LocalModelCache), err
}

// UpdateStatus was generated because the type contains a Status member.
// Add a +genclient:noStatus comment above the type to avoid generating UpdateStatus().
func (c *FakeLocalModelCaches) UpdateStatus(ctx context.Context, localModelCache *v1alpha1.LocalModelCache, opts v1.UpdateOptions) (result *v1alpha1.LocalModelCache, err error) {
	emptyResult := &v1alpha1.LocalModelCache{}
	obj, err := c.Fake.
		Invokes(testing.NewUpdateSubresourceActionWithOptions(localmodelcachesResource, "status", c.ns, localModelCache, opts), emptyResult)

	if obj == nil {
		return emptyResult, err
	}
	return obj.(*v1alpha1.LocalModelCache), err
}

// Delete takes name of the localModelCache and deletes it. Returns an error if one occurs.
func (c *FakeLocalModelCaches) Delete(ctx context.Context, name string, opts v1.DeleteOptions) error {
	_, err := c.Fake.
		Invokes(testing.NewDeleteActionWithOptions(localmodelcachesResource, c.ns, name, opts), &v1alpha1.LocalModelCache{})

	return err
}

// DeleteCollection deletes a collection of objects.
func (c *FakeLocalModelCaches) DeleteCollection(ctx context.Context, opts v1.DeleteOptions, listOpts v1.ListOptions) error {
	action := testing.NewDeleteCollectionActionWithOptions(localmodelcachesResource, c.ns, opts, listOpts)

	_, err := c.Fake.Invokes(action, &v1alpha1.LocalModelCacheList{})
	return err
}

// Patch applies the patch and returns the patched localModelCache.
func (c *FakeLocalModelCaches) Patch(ctx context.Context, name string, pt types.PatchType, data []byte, opts v1.PatchOptions, subresources ...string) (result *v1alpha1.LocalModelCache, err error) {
	emptyResult := &v1alpha1.LocalModelCache{}
	obj, err := c.Fake.
		Invokes(testing.NewPatchSubresourceActionWithOptions(localmodelcachesResource, c.ns, name, pt, data, opts, subresources...), emptyResult)

	if obj == nil {
		return emptyResult, err
	}
	return obj.(*v1alpha1.LocalModelCache), err
}

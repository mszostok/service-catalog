/*
Copyright 2019 The Kubernetes Authors.

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

package mutation

import (
	"context"
	"encoding/json"
	"net/http"

	sc "github.com/kubernetes-sigs/service-catalog/pkg/apis/servicecatalog/v1beta1"
	admissionTypes "k8s.io/api/admission/v1beta1"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

// CreateUpdateHandler handles ClusterServiceBroker
type CreateUpdateHandler struct {
	// Decoder decodes objects
	decoder *admission.Decoder
}

var _ admission.Handler = &CreateUpdateHandler{}
var _ admission.DecoderInjector = &CreateUpdateHandler{}

func (h *CreateUpdateHandler) Handle(ctx context.Context, req admission.Request) admission.Response {
	cb := &sc.ClusterServiceBroker{}
	if err := h.decoder.Decode(req, cb); err != nil {
		return admission.Errored(http.StatusBadRequest, err)
	}

	switch req.Operation {
	case admissionTypes.Create:
		h.mutateOnCreate(ctx, cb)
	case admissionTypes.Update:
		oldObj := &sc.ClusterServiceBroker{}
		if err := h.decoder.DecodeRaw(req.OldObject, oldObj); err != nil {
			return admission.Errored(http.StatusBadRequest, err)
		}
		h.mutateOnUpdate(ctx, oldObj, cb)
	default:
		return admission.Allowed("action not taken")
	}

	rawMutated, err := json.Marshal(cb)
	if err != nil {
		return admission.Errored(http.StatusInternalServerError, err)
	}

	return admission.PatchResponseFromRaw(req.Object.Raw, rawMutated)
}

func (h *CreateUpdateHandler) mutateOnCreate(ctx context.Context, sb *sc.ClusterServiceBroker) {
	sb.Finalizers = []string{sc.FinalizerServiceCatalog}

	if sb.Spec.RelistBehavior == "" {
		sb.Spec.RelistBehavior = sc.ServiceBrokerRelistBehaviorDuration
	}
}

func (h *CreateUpdateHandler) mutateOnUpdate(ctx context.Context, oldClusterServiceBroker, newClusterServiceBroker *sc.ClusterServiceBroker) {
	// Ignore the RelistRequests field when it is the default value
	if newClusterServiceBroker.Spec.RelistRequests == 0 {
		newClusterServiceBroker.Spec.RelistRequests = oldClusterServiceBroker.Spec.RelistRequests
	}
}

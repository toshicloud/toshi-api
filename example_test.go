package api_test

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync"

	"connectrpc.com/connect"
	"google.golang.org/genproto/googleapis/rpc/errdetails"

	"go.toshicloud.io/api/contract"
	workspacev1 "go.toshicloud.io/api/workspacev1"
	"go.toshicloud.io/api/workspacev1/workspacev1connect"
)

// Example_firstCalls makes a client, lists a project's images, creates one
// with a request key, and reads the reason of a refusal. It runs against a
// small in-process stand-in for the Workspace API's image calls; against
// Toshi, serverURL is the API's address and httpClient sends the API token.
func Example_firstCalls() {
	server := httptest.NewServer(imageStandIn())
	defer server.Close()
	httpClient, serverURL := server.Client(), server.URL

	ctx := context.Background()
	client := workspacev1connect.NewImageServiceClient(httpClient, serverURL)

	list, err := client.ListImages(ctx, connect.NewRequest(&workspacev1.ListImagesRequest{
		Project: "default",
	}))
	if err != nil {
		fmt.Println("list:", err)
		return
	}
	fmt.Println("images:", len(list.Msg.GetImages()))

	// A request key makes a create safe to send again, after a timeout for
	// instance: the same key and request return the first answer, and no
	// second image is made.
	create := &workspacev1.CreateImageRequest{
		Project:    "default",
		Name:       "web",
		Kind:       workspacev1.ImageKind_IMAGE_KIND_CONTAINER,
		RequestKey: "create-web-1",
	}
	for range 2 {
		res, err := client.CreateImage(ctx, connect.NewRequest(create))
		if err != nil {
			fmt.Println("create:", err)
			return
		}
		fmt.Println("created:", res.Msg.GetImage().GetName())
	}

	// A new request for a name the workspace has is refused. The refusal's
	// code says what kind of failure it is; its google.rpc.ErrorInfo, in the
	// domain contract.RefusalDomain, has the reason a program branches on,
	// one of the contract package's Reason constants, and its metadata.
	_, err = client.CreateImage(ctx, connect.NewRequest(&workspacev1.CreateImageRequest{
		Project:    "default",
		Name:       "web",
		Kind:       workspacev1.ImageKind_IMAGE_KIND_CONTAINER,
		RequestKey: "create-web-2",
	}))
	if info, ok := refusal(err); ok && info.GetReason() == contract.ReasonImageNameTaken {
		fmt.Println("refused:", connect.CodeOf(err), info.GetReason(), info.GetMetadata()["name"])
	}
	// Output:
	// images: 0
	// created: web
	// created: web
	// refused: already_exists IMAGE_NAME_TAKEN web
}

// refusal returns the ErrorInfo of a refusal from Toshi, and false for an
// error that carries none.
func refusal(err error) (*errdetails.ErrorInfo, bool) {
	var cerr *connect.Error
	if !errors.As(err, &cerr) {
		return nil, false
	}
	for _, detail := range cerr.Details() {
		value, err := detail.Value()
		if err != nil {
			continue
		}
		if info, ok := value.(*errdetails.ErrorInfo); ok && info.GetDomain() == contract.RefusalDomain {
			return info, true
		}
	}
	return nil, false
}

// images is the stand-in's state: the images by name, and the answer to
// each request key.
type images struct {
	workspacev1connect.UnimplementedImageServiceHandler

	mu     sync.Mutex
	byName map[string]*workspacev1.Image
	keys   map[string]*workspacev1.CreateImageResponse
}

// imageStandIn serves ListImages and CreateImage the way the Workspace API
// answers them, for one project, and nothing else.
func imageStandIn() http.Handler {
	mux := http.NewServeMux()
	mux.Handle(workspacev1connect.NewImageServiceHandler(&images{
		byName: map[string]*workspacev1.Image{},
		keys:   map[string]*workspacev1.CreateImageResponse{},
	}))
	return mux
}

func (s *images) ListImages(_ context.Context, _ *connect.Request[workspacev1.ListImagesRequest]) (*connect.Response[workspacev1.ListImagesResponse], error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res := &workspacev1.ListImagesResponse{}
	for _, name := range slices.Sorted(maps.Keys(s.byName)) {
		res.Images = append(res.Images, s.byName[name])
	}
	return connect.NewResponse(res), nil
}

func (s *images) CreateImage(_ context.Context, req *connect.Request[workspacev1.CreateImageRequest]) (*connect.Response[workspacev1.CreateImageResponse], error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := req.Msg
	if res, ok := s.keys[m.GetRequestKey()]; ok {
		return connect.NewResponse(res), nil
	}
	if _, ok := s.byName[m.GetName()]; ok {
		cerr := connect.NewError(connect.CodeAlreadyExists, fmt.Errorf("an image named %q already exists in the workspace", m.GetName()))
		detail, err := connect.NewErrorDetail(&errdetails.ErrorInfo{
			Domain:   contract.RefusalDomain,
			Reason:   contract.ReasonImageNameTaken,
			Metadata: map[string]string{"name": m.GetName()},
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		cerr.AddDetail(detail)
		return nil, cerr
	}
	img := &workspacev1.Image{Name: m.GetName(), Kind: m.GetKind()}
	s.byName[img.GetName()] = img
	res := &workspacev1.CreateImageResponse{Image: img}
	if key := m.GetRequestKey(); key != "" {
		s.keys[key] = res
	}
	return connect.NewResponse(res), nil
}

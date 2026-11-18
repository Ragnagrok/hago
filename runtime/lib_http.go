// An HTTP client, for Network.HTTP. A program gets this part of the runtime
// only if it uses one of its functions; see runtime.go.
package main

import (
	rt_io "io"
	rt_http "net/http"
	rt_strings "strings"
)

// --- runtime ---

// What a server answered: its status and the whole body.
type rt_HttpResponse struct {
	Status int
	Body   string
}

func rt_httpResponse(r *rt_http.Response, err error) (rt_HttpResponse, error) {
	if err != nil {
		return rt_HttpResponse{}, err
	}
	defer r.Body.Close()
	b, err := rt_io.ReadAll(r.Body)
	return rt_HttpResponse{r.StatusCode, string(b)}, err
}

func rt_httpGet(url string) (rt_HttpResponse, error) { return rt_httpResponse(rt_http.Get(url)) }

func rt_httpPost(url, contentType, body string) (rt_HttpResponse, error) {
	return rt_httpResponse(rt_http.Post(url, contentType, rt_strings.NewReader(body)))
}

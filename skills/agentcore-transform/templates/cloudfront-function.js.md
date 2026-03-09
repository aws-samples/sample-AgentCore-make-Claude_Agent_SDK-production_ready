# Template: infra/cloudfront-function.js

CloudFront Function that injects a WebSocket token from query string
into the Authorization header.

This is needed because browsers cannot set custom headers on WebSocket
upgrade requests. The frontend passes the JWT as `?token=<jwt>` and
this function converts it to `Authorization: Bearer <jwt>` before the
request reaches AgentCore.

```javascript
function handler(event) {
  var request = event.request;
  var qs = request.querystring;

  // If token is in query string, inject as Authorization header
  if (qs.token && qs.token.value) {
    request.headers['authorization'] = {
      value: 'Bearer ' + qs.token.value
    };
  }

  return request;
}
```

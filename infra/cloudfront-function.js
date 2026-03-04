// CloudFront Function: WebSocket auth
// Extracts token and sessionId from query params and injects them as HTTP headers.
// Runs on viewer-request for the /ws* path pattern.
//
// CloudFront Functions use the cloudfront-js-2.0 runtime (ES5-like subset).
// Query param keys are case-sensitive — must match the frontend URL exactly.

function handler(event) {
  var request = event.request;
  var params = request.querystring;

  // token query param → Authorization header (then strip from query string)
  if (params.token) {
    request.headers['authorization'] = { value: 'Bearer ' + params.token.value };
    delete params.token;
  }

  // sessionId → X-Amzn-Bedrock-AgentCore-Runtime-Session-Id header
  // Keep in query string too (AgentCore WS session routing accepts both)
  if (params.sessionId) {
    request.headers['x-amzn-bedrock-agentcore-runtime-session-id'] = {
      value: params.sessionId.value
    };
  }

  return request;
}

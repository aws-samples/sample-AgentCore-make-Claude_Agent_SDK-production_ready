# Template: infra/template.yaml

CloudFormation template for S3 + CloudFront frontend hosting with AgentCore backend routing.

Only generate this file if the application has a frontend.
See `references/frontend-deployment.md` for full documentation.

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Description: "Frontend hosting with AgentCore backend routing"

Parameters:
  EncodedAgentArn:
    Type: String
    Description: "URL-encoded AgentCore agent ARN"
  AwsRegion:
    Type: String
    Default: "us-east-1"

Resources:
  FrontendBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub "${AWS::StackName}-frontend-${AWS::AccountId}"
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true

  FrontendBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Properties:
      Bucket: !Ref FrontendBucket
      PolicyDocument:
        Version: "2012-10-17"
        Statement:
          - Effect: Allow
            Principal:
              Service: cloudfront.amazonaws.com
            Action: s3:GetObject
            Resource: !Sub "${FrontendBucket.Arn}/*"
            Condition:
              StringEquals:
                AWS:SourceArn: !Sub "arn:aws:cloudfront::${AWS::AccountId}:distribution/${CloudFrontDistribution}"

  OAC:
    Type: AWS::CloudFront::OriginAccessControl
    Properties:
      OriginAccessControlConfig:
        Name: !Sub "${AWS::StackName}-oac"
        OriginAccessControlOriginType: s3
        SigningBehavior: always
        SigningProtocol: sigv4

  TokenInjectionFunction:
    Type: AWS::CloudFront::Function
    Properties:
      Name: !Sub "${AWS::StackName}-token-inject"
      AutoPublish: true
      FunctionCode: !Sub |
        function handler(event) {
          var request = event.request;
          var qs = request.querystring;
          if (qs.token && qs.token.value) {
            request.headers['authorization'] = { value: 'Bearer ' + qs.token.value };
          }
          return request;
        }
      FunctionConfig:
        Comment: "Inject token query param as Authorization header"
        Runtime: cloudfront-js-2.0

  CloudFrontDistribution:
    Type: AWS::CloudFront::Distribution
    Properties:
      DistributionConfig:
        Enabled: true
        DefaultRootObject: index.html
        HttpVersion: http2and3

        Origins:
          - Id: S3Origin
            DomainName: !GetAtt FrontendBucket.RegionalDomainName
            OriginAccessControlId: !Ref OAC
            S3OriginConfig:
              OriginAccessIdentity: ""

          - Id: AgentCoreRestOrigin
            DomainName: !Sub "bedrock-agentcore.${AwsRegion}.amazonaws.com"
            OriginPath: !Sub "/runtimes/${EncodedAgentArn}"
            CustomOriginConfig:
              OriginProtocolPolicy: https-only
              HTTPSPort: 443
              OriginSSLProtocols: [TLSv1.2]

          - Id: AgentCoreWsOrigin
            DomainName: !Sub "bedrock-agentcore.${AwsRegion}.amazonaws.com"
            OriginPath: !Sub "/runtimes/${EncodedAgentArn}"
            CustomOriginConfig:
              OriginProtocolPolicy: https-only
              HTTPSPort: 443
              OriginSSLProtocols: [TLSv1.2]

        DefaultCacheBehavior:
          TargetOriginId: S3Origin
          ViewerProtocolPolicy: redirect-to-https
          CachePolicyId: 658327ea-f89d-4fab-a63d-7e88639e58f6
          Compress: true

        CacheBehaviors:
          - PathPattern: "/invocations*"
            TargetOriginId: AgentCoreRestOrigin
            ViewerProtocolPolicy: https-only
            AllowedMethods: [GET, HEAD, OPTIONS, PUT, PATCH, POST, DELETE]
            CachePolicyId: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad
            OriginRequestPolicyId: 216adef6-5c7f-47e4-b989-5492eafa07d3
            Compress: false

          - PathPattern: "/ws*"
            TargetOriginId: AgentCoreWsOrigin
            ViewerProtocolPolicy: https-only
            AllowedMethods: [GET, HEAD, OPTIONS, PUT, PATCH, POST, DELETE]
            CachePolicyId: 4135ea2d-6df8-44a3-9df3-4b5a84be39ad
            OriginRequestPolicyId: 216adef6-5c7f-47e4-b989-5492eafa07d3
            FunctionAssociations:
              - EventType: viewer-request
                FunctionARN: !GetAtt TokenInjectionFunction.FunctionARN
            Compress: false

        CustomErrorResponses:
          - ErrorCode: 403
            ResponseCode: 200
            ResponsePagePath: /index.html
          - ErrorCode: 404
            ResponseCode: 200
            ResponsePagePath: /index.html

Outputs:
  BucketName:
    Value: !Ref FrontendBucket
  DistributionId:
    Value: !Ref CloudFrontDistribution
  DistributionDomain:
    Value: !GetAtt CloudFrontDistribution.DomainName
```

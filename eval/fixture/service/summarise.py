import json
import boto3

bedrock = boto3.client("bedrock-runtime")


def summarise(transcript: str) -> str:
    resp = bedrock.invoke_model(
        modelId="anthropic.claude-3-5-sonnet-20241022-v2:0",
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 512,
            "messages": [{"role": "user", "content": f"Summarise:\n{transcript}"}],
        }),
    )
    return json.loads(resp["body"].read())["content"][0]["text"]

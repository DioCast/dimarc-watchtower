import sys
import asyncio
import subprocess
import os

# --- CORRECTED IMPORTS ---
# We act as a CLIENT to the Cloud (SSE)
from mcp.client.sse import sse_client
# We act as a SERVER to Claude (Stdio)
from mcp.server.stdio import stdio_server
# -------------------------

# --- CONFIGURATION ---
SERVER_URL = "https://dimarc-watchtower-backend-prod-293550889950.us-west4.run.app/sse"
# ---------------------

async def main():
    # 1. Get the Google Identity Token
    try:
        token = subprocess.check_output(
            ["/usr/local/bin/gcloud", "auth", "print-identity-token"], 
            text=True
        ).strip()
    except Exception as e:
        sys.stderr.write(f"Error getting gcloud token: {e}\n")
        sys.exit(1)

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "text/event-stream"
    }

    # 2. Connect to the Cloud Server (SSE)
    async with sse_client(SERVER_URL, headers=headers) as (read_stream, write_stream):
        
        # 3. Connect to Claude (Stdio)
        async with stdio_server() as (read_stdio, write_stdio):
            
            # Task A: Cloud -> Claude
            async def cloud_to_claude():
                async for message in read_stream:
                    await write_stdio.send(message)

            # Task B: Claude -> Cloud
            async def claude_to_cloud():
                async for message in read_stdio:
                    await write_stream.send(message)

            # Run both until one fails
            await asyncio.gather(cloud_to_claude(), claude_to_cloud())

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
    except Exception as e:
        sys.stderr.write(f"Bridge Error: {e}\n")
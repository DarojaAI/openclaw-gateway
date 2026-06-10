# Discord Bot — Version Query Integration

This guide shows how the Discord bot (or any other bot) can reliably query the VM version using the new Version API.

## The Problem

Previously, the Discord bot tried to query version info from an OpenCLAW agent workspace (`/home/desktopuser/Projects/test-agent`), which may not exist or may not be properly initialized. This caused the bot to report a stale version (e.g., `1.0.0`) instead of the actual deployed version (e.g., `v1.7.1`).

## The Solution

Use the **Version API** HTTP endpoint instead. It's reliable, language-agnostic, and requires no agent setup.

## Implementation

### Node.js / JavaScript

```javascript
const axios = require('axios');

/**
 * Fetch VM version from the Version API
 * @param {string} vmIp - IP address of the VM
 * @returns {Promise<object>} Version data { version, commit, environment, deployed, ref }
 */
async function getVMVersion(vmIp) {
  try {
    const response = await axios.get(`http://${vmIp}:8765/version/json`, {
      timeout: 5000
    });
    return response.data;
  } catch (error) {
    console.error(`Version API error: ${error.message}`);
    return null;
  }
}

// In your Discord bot command handler:
const client = new Discord.Client();

client.on('messageCreate', async (message) => {
  if (message.content === '!version') {
    const vmIp = process.env.LINUX_DESKTOP_VM_IP; // Set this in your bot config
    const versionData = await getVMVersion(vmIp);

    if (!versionData) {
      message.reply('❌ Could not reach version API');
      return;
    }

    const embed = new Discord.EmbedBuilder()
      .setTitle('📊 VM Version Info')
      .setURL(versionData.commit_url)
      .addFields(
        { name: 'Version', value: versionData.version, inline: true },
        { name: 'Environment', value: versionData.environment, inline: true },
        { name: 'Commit', value: `[${versionData.commit.substring(0, 8)}](${versionData.commit_url})`, inline: true },
        { name: 'Deployed', value: new Date(versionData.deployed).toLocaleString(), inline: true }
      )
      .setColor('#0099ff');

    message.reply({ embeds: [embed] });
  }
});
```

### Python

```python
import os
import requests
from datetime import datetime

def get_vm_version(vm_ip: str) -> dict | None:
    """Fetch VM version from the Version API."""
    try:
        response = requests.get(
            f'http://{vm_ip}:8765/version/json',
            timeout=5
        )
        response.raise_for_status()
        return response.json()
    except requests.RequestException as e:
        print(f'Version API error: {e}')
        return None

# In your Discord.py command:
@bot.command()
async def version(ctx):
    vm_ip = os.getenv('LINUX_DESKTOP_VM_IP')
    version_data = get_vm_version(vm_ip)

    if not version_data:
        await ctx.send('❌ Could not reach version API')
        return

    deployed_date = datetime.fromisoformat(version_data['deployed'].replace('Z', '+00:00'))

    embed = discord.Embed(
        title='📊 VM Version Info',
        url=version_data['commit_url'],
        color=discord.Color.blue()
    )
    embed.add_field(name='Version', value=version_data['version'], inline=True)
    embed.add_field(name='Environment', value=version_data['environment'], inline=True)
    embed.add_field(name='Commit', value=f"[{version_data['commit'][:8]}]({version_data['commit_url']})", inline=True)
    embed.add_field(name='Deployed', value=deployed_date.strftime('%Y-%m-%d %H:%M:%S UTC'), inline=True)

    await ctx.send(embed=embed)
```

### Bash / curl

```bash
#!/bin/bash
VM_IP="${1:-135.181.44.237}"

# Fetch version as JSON
curl -s "http://${VM_IP}:8765/version/json" | jq '.'

# Or just the version string
echo "Current version: $(curl -s http://${VM_IP}:8765/version)"
```

## Environment Variables

Set these in your bot's configuration:

```bash
# .env or config file
LINUX_DESKTOP_VM_IP=135.181.44.237  # The VM's public IP
LINUX_DESKTOP_VM_PORT=8765          # Version API port (optional, defaults to 8765)
```

## Error Handling

Always handle the case where the API is unreachable:

```javascript
// JavaScript/Node.js
async function getVMVersion(vmIp) {
  try {
    const response = await axios.get(`http://${vmIp}:8765/version/json`, {
      timeout: 5000
    });
    return response.data;
  } catch (error) {
    if (error.code === 'ECONNREFUSED') {
      console.warn('Version API is not running');
    } else if (error.code === 'ENOTFOUND') {
      console.warn('Cannot resolve VM IP address');
    } else if (error.code === 'ETIMEDOUT') {
      console.warn('Version API request timed out');
    }
    return null;
  }
}
```

## Response Format

### Success Response (200 OK)

```json
{
  "version": "1.7.1",
  "commit": "a1b2c3d4e5f6789012345678901234567890abcd",
  "commit_url": "https://github.com/DarojaAI/linux-desktop-seed/commit/a1b2c3d4e5f6789012345678901234567890abcd",
  "environment": "test",
  "deployed": "2026-05-06T14:30:00Z",
  "ref": "v1.7.1",
  "timestamp": "2026-05-06T15:45:32Z"
}
```

### 404 Not Found

Endpoint doesn't exist (check the path — valid endpoints are `/version`, `/version/json`, `/health`).

### Connection Refused

The Version API is not running. This should not happen if the deployment completed successfully, but the service can be restarted with:

```bash
ssh root@VM_IP systemctl restart version-api.service
```

## Testing

Before deploying to production, test the API:

```bash
# From your local machine
curl -v http://135.181.44.237:8765/version/json

# From within the bot environment
python -c "import requests; print(requests.get('http://135.181.44.237:8765/version/json').json())"
```

## Deployment Checklist

- [ ] Update bot code to use Version API endpoints
- [ ] Set `LINUX_DESKTOP_VM_IP` environment variable in bot config
- [ ] Test API connectivity from bot environment
- [ ] Update bot command to call `getVMVersion()` instead of agent-based method
- [ ] Verify bot reports correct version after deployment
- [ ] Remove old agent-workspace-based version query code

## See Also

- [Version API Documentation](./VERSION_API.md)
- [OpenCLAW Configuration](config-management.md)
- [Deployment Guide](./DEPLOYMENT-GUIDE.md)

# Lazre RAG Chatbot

_TODO explanations about how cool it is and its features_


# How to run the docker container

## Prepare configuration files

You will need to obtain the following keys to run the chat bot:
 - _OPENAI_API_KEY_
 - Telegrap _API_ID_ and _API_HASH_
 - _TELEGRAM_BOT_TOKEN_

 The instructions below explain how to prepare those.

### 1. Environment Variables (.env)
Create a `.env` file with the following content:
```bash
# OpenAI API key for language model operations, see https://platform.openai.com/docs/libraries#create-and-export-an-api-key
# IMPORTANT: Set up usage limits in your OpenAI project settings to prevent unexpected charges!
OPENAI_API_KEY=your_openai_api_key_here

# Telegram Bot Token (get it from @BotFather)
# See documentation here: https://core.telegram.org/bots#how-do-i-create-a-bot
TELEGRAM_BOT_TOKEN=your_telegram_bot_token_here
```

### 2. Telegram API Configuration (config_taggregator.json)
Create `config` folder and create `config_taggregator.json` file in it.
(How to get `API ID` and `API HASH` is explained here https://docs.telethon.dev/en/stable/basic/signing-in.html)
```json
{
    "api_id": "your_telegram_api_id",
    "api_hash": "your_telegram_api_hash",
    "phone_number": "your_phone_number",
}
```

To get Telegram API credentials:
1. Visit https://my.telegram.org/auth
2. Log in with your phone number
3. Go to 'API development tools'
4. Create a new application
5. Copy `api_id` and `api_hash`


## Run the docker image

When you run the container for the first time, you'll need to authenticate with Telegram:
1. The container will prompt you to enter the verification code sent to your Telegram app
2. Enter the code when prompted
3. After successful authentication, the container will start an initial setup process. It will prompt for chat selection and other parameters.

### 1. Start docker container

#### Linux/macOS
```bash
docker pull ghcr.io/nullptre/lazre-box:latest

# '-it' is only needed for the first run, to set up the telegram client, then it's not required
docker run -it \
  -v ./.workdir:/var/lib/lazre \
  -v ./config:/var/lib/lazre/config \
  --env-file .env \
  ghcr.io/nullptre/lazre-box:latest
```

#### Windows (PowerShell)
```powershell
docker pull ghcr.io/nullptre/lazre-box:latest

# '-it' is only needed for the first run, to set up the telegram client, then it's not required
docker run -it `
  -v .\.workdir:/var/lib/lazre `
  -v .\config:/var/lib/lazre/config `
  --env-file .env `
  ghcr.io/nullptre/lazre-box:latest
```

### 2. Run health check and indexing

a. Open your telegram bot (it will be your primary interface to work with all functions).

b. Run health check by typing `/hc`. Then wait for the response and verify if it was successful.

c. Run indexing by typing `/index_topics`.

   **WARNING** The initial indexing process may consume a significant amount of money on your OpenAI account! Please ensure you have set up usage limits in the OpenAI platform before proceeding.
   The indexing may take hours or even days depending on the amount of data in the chat history.

### 3. Use the chatbot

Once indexing is finished you can use the chatbot.
You should periodically run `/index_topics` command manually that will incrementally index latest chat messages. Recommended: once per several days.



# How to build the Image

If you get a "no space left on device" error, try cleaning up Docker:

```bash
# Remove unused images and build cache
# docker image prune -a
docker builder prune -f

# Check Docker disk usage
docker system df
```

Then build the image:
```bash
# Build the image
./build-docker-locally.sh 
```

# Use the official lightweight Python image.
# https://hub.docker.com/_/python
FROM python:3.12-slim

# Copy local code to the container image.
ENV APP_HOME /app
WORKDIR $APP_HOME
COPY --chown=bin:bin . ./
RUN pip install 'setuptools<81' -r requirements.txt
RUN apt update -y
RUN apt install ffmpeg -y
ENV GOOGLE_APPLICATION_CREDENTIALS=/app/vmExeModule.json
#ENTRYPOINT ["python3","main.py"]

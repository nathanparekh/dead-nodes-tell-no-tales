FROM python:3.11-slim
WORKDIR /app
COPY udp_script.py .
ENTRYPOINT ["python", "udp_script.py"]

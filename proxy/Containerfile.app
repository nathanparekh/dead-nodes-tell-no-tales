FROM python:3.11-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY udp_script.py .
ENTRYPOINT ["python","-u", "udp_script.py"]

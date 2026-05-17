FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

RUN pip install --no-cache-dir opentimestamps-client==0.7.2

WORKDIR /app
COPY server.py /app/server.py

ENV PORT=8080
CMD ["python", "/app/server.py"]

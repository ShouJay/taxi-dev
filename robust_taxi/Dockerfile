# 使用官方 Python 運行時作為父鏡像
FROM python:3.10-slim-buster

# 設置工作目錄
WORKDIR /app

# 複製依賴文件
COPY requirements.txt .

# 安裝依賴
RUN pip install --no-cache-dir -r requirements.txt

# 複製應用程序代碼
COPY src ./src
COPY tests ./tests
COPY run_app.py .

# 複製 HTML 檔案
COPY *.html ./

# 暴露應用程序運行端口
EXPOSE 8080
ENV PORT=8080

# 設置健康檢查
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1

# # 運行應用程序
# CMD ["python", "run_app.py"]

# 運行應用程序 (使用 Gunicorn)
CMD ["gunicorn", "--worker-class", "eventlet", "-w", "1", "-b", "0.0.0.0:8080", "src.app:app", "--access-logfile", "-", "--error-logfile", "-"]

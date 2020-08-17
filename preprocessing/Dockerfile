FROM python:3.7

RUN pip install boto3
RUN pip install opencv-python
RUN pip install numpy
RUN pip install pandas

WORKDIR /usr/local

COPY preprocessing.py preprocessing.py

ENTRYPOINT [ "python", "./preprocessing.py" ]
CMD [ "--infile=test" ]
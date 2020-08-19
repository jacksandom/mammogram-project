import boto3
import os
import pydicom as dicom
import multiprocessing as mp
import cv2
import sys


def download_s3_file(bucketName, filePath):
    s3_resource = boto3.resource('s3')
    bucket = s3_resource.Bucket(bucketName)
    if not os.path.exists(os.path.dirname(filePath)):
        os.makedirs(os.path.dirname(filePath))
        bucket.download_file(filePath, filePath)


def convert_to_png(filePath):
    ds = dicom.dcmread(filePath)
    pixel_array = ds.pixel_array.astype('float64')
    pixel_array *= 255./pixel_array.max() #normalize image pixels
    pixel_array = pixel_array.astype('uint8')
    new_file_path = filePath.replace('.dcm', '.png')
    new_file_path = os.path.join('PNG-Images', '/'.join(new_file_path.split('/')[1:]))
    if not os.path.exists('/'.join(new_file_path.split('/')[:-1])):
        os.makedirs('/'.join(new_file_path.split('/')[:-1]))
    cv2.imwrite(new_file_path, pixel_array)
    return new_file_path.replace("\\", "/")


def upload_s3_file(bucketName, filePath):
    s3 = boto3.client('s3')
    s3.upload_file(filePath, bucketName, filePath)


def conversion(filePath):
    download_s3_file(filePath[0], filePath[1])
    newFilePath = convert_to_png(filePath[1])
    upload_s3_file(filePath[0], newFilePath)
    os.remove(filePath[1])
    os.remove(newFilePath)


if __name__ == '__main__':

    bucket_name = sys.argv[1]
    directory_name = sys.argv[2]

    file_paths = []
    s3_resource = boto3.resource('s3')
    bucket = s3_resource.Bucket(bucket_name)
    objects = bucket.objects.filter(Prefix=directory_name)
    for obj in objects:
        file_paths.append((bucket_name, obj.key))

    pool = mp.Pool()
    pool.map(conversion, file_paths)
    pool.close()

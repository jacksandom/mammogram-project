import boto3
import os
import pydicom as dicom
import multiprocessing as mp
import cv2


def download_s3_folder(bucketName, directoryName):
    s3_resource = boto3.resource('s3')
    bucket = s3_resource.Bucket(bucketName)
    objects = bucket.objects.filter(Prefix=directoryName)
    for obj in objects:
        if not os.path.exists(os.path.dirname(obj.key)):
            os.makedirs(os.path.dirname(obj.key))
        if os.path.split(obj.key)[1] != '':
            bucket.download_file(obj.key, obj.key)


def convert_to_png(file_path):
    (root, file) = file_path
    ds = dicom.dcmread(os.path.join(root, file))
    pixel_array = ds.pixel_array.astype('float64')
    pixel_array *= 255./pixel_array.max() #normalize image pixels
    pixel_array = pixel_array.astype('uint8')
    new_file = file.replace('.dcm', '.png')
    new_dir = os.path.join('PNG-Images', '/'.join(root.split('/')[1:]))
    if not os.path.exists(new_dir):
        os.makedirs(new_dir)
    cv2.imwrite(os.path.join(new_dir, new_file), pixel_array)


def upload_s3_folder(bucketName):
    s3 = boto3.client('s3')
    for root,dirs,files in os.walk('PNG-Images'):
        for file in files:
            #print(os.path.join(root,file).replace('\\', '/'))
            s3.upload_file(os.path.join(root,file), bucketName, os.path.join(root,file).replace('\\', '/'))


if __name__ == '__main__':

    bucket_name = 'mammogram-images'
    directory_name = 'CBIS-DDSM-Mini'

    download_s3_folder(bucket_name, directory_name)

    file_paths = []
    for root, dirs, files in os.walk(directory_name):
            for file in files:
                if file.endswith(".dcm"):
                    file_paths.append((root.replace('\\', '/'), file))

    pool = mp.Pool()
    pool.map(convert_to_png, file_paths)
    pool.close()
    
    upload_s3_folder(bucket_name)

export interface FileToken {
  fd: number;
  path: string;
  name: string;
}

export interface FileStat {
  size: number;
  isFile: boolean;
  isDirectory: boolean;
}

export interface BufferIoOptions {
  offset?: number;
  length?: number;
}

export class FileTokenRecord implements FileToken {
  fd: number;
  path: string;
  name: string;

  constructor(fd: number, path: string, name: string) {
    this.fd = fd;
    this.path = path;
    this.name = name;
  }
}

export class FileStatRecord implements FileStat {
  size: number;
  isFile: boolean;
  isDirectory: boolean;

  constructor(size: number, isFile: boolean, isDirectory: boolean) {
    this.size = size;
    this.isFile = isFile;
    this.isDirectory = isDirectory;
  }
}

export class BufferIoOptionsRecord implements BufferIoOptions {
  offset?: number;
  length?: number;

  constructor(offset?: number, length?: number) {
    this.offset = offset;
    this.length = length;
  }
}

export interface FileDriver {
  mkdir(path: string, recursive: boolean): Promise<void>;
  list(path: string): Promise<string[]>;
  stat(path: string): Promise<FileStat>;
  statIfPresent(path: string): Promise<FileStat | undefined>;
  open(path: string, mode: number): Promise<FileToken>;
  close(file: number | FileToken): Promise<void>;
  read(fd: number, buffer: ArrayBuffer, options?: BufferIoOptions): Promise<number>;
  write(fd: number, buffer: ArrayBuffer | string, options?: BufferIoOptions): Promise<number>;
  unlink(path: string): Promise<void>;
  rmdir(path: string): Promise<void>;
  renameNoOverwrite(source: string, destination: string): Promise<void>;
  renameReplace(source: string, destination: string): Promise<void>;
  hash(path: string, algorithm: string): Promise<string>;
}

export const FILE_OPEN_MODE_READ_ONLY: number = 0o0;
export const FILE_OPEN_MODE_WRITE_ONLY: number = 0o1;
export const FILE_OPEN_MODE_READ_WRITE: number = 0o2;
export const FILE_OPEN_MODE_CREATE: number = 0o100;
export const FILE_OPEN_MODE_TRUNC: number = 0o1000;
export const FILE_OPEN_MODE_APPEND: number = 0o2000;
export const FILE_MOVE_MODE_OVERWRITE: number = 0;
export const FILE_MOVE_MODE_NO_OVERWRITE: number = 1;

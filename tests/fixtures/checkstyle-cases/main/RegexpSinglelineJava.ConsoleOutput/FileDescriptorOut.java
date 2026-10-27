package cases;

import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.OutputStream;

class FileDescriptorOut {

  OutputStream stream() {
    return new FileOutputStream(FileDescriptor.out);
  }
}

import { common } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ByteCodec } from '../../util/ByteCodec';
import { BusinessError } from '@kit.BasicServicesKit';

// Disposable UI fixtures only. This source is injected into a temporary build.
export async function verifyDeviceStorage(context: common.Context): Promise<void> {
  const marker = '__HT_PROBE_MARKER__';
  const contents: string[] = __HT_CONTENTS__;
  const names: string[] = __HT_NAMES__;
  const remove: string[] = __HT_REMOVE__;
  try {
    await new Promise<void>((resolve): void => { setTimeout(resolve, 2500); });
    for (let uri of remove) {
      const file = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.closeSync(file);
      if (fileIo.statSync(uri).size !== 0) throw new Error('fixture truncation failed');
      try { fileIo.unlinkSync(uri); } catch (_error) {}
    }
    for (let i = 0; i < contents.length; i++) {
      const selected = await new picker.DocumentViewPicker(context).save({ newFileNames: [names[i]] });
      if (selected.length !== 1) throw new Error('save cancelled');
      const file = fileIo.openSync(selected[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const bytes = ByteCodec.decodeBytes(ByteCodec.encodeText(contents[i]));
      try { fileIo.writeSync(file.fd, bytes.buffer); } finally { fileIo.closeSync(file); bytes.fill(0); }
      hilog.info(0x0000, 'HTDeviceProbe', '%{public}s URI %{public}s', marker, selected[0]);
    }
    hilog.info(0x0000, 'HTDeviceProbe', '%{public}s PASS', marker);
  } catch (error) { hilog.error(0x0000, 'HTDeviceProbe', '%{public}s FAIL code=%{public}d', marker, (error as BusinessError).code ?? 0); }
}

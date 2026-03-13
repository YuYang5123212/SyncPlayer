import { media } from '@kit.MediaKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { window, promptAction } from '@kit.ArkUI';

// 声明全局持久化存储
PersistentStorage.persistProp<string>('virtualFilesJson', '[]');
PersistentStorage.persistProp<string>('lastPlayUri', '');
PersistentStorage.persistProp<number>('lastPlayTime', 0);

// 核心数据结构接口
interface VideoItem {
  videoUri: string;
  name: string;
  baseName: string;
  folderName: string;
  srtUri: string | null;
  srtName: string | null;
}

// 解决 ERROR 1：为解析出的路径信息专门定义一个接口
interface UriInfo {
  name: string;
  folderName: string;
  baseName: string;
}

@Entry
@Component
struct Index {
  @State currentView: 'HOME' | 'PLAYER' = 'HOME';

  @StorageLink('virtualFilesJson') virtualFilesJson: string = '[]';
  @StorageLink('lastPlayUri') lastPlayUri: string = '';
  @StorageLink('lastPlayTime') lastPlayTime: number = 0;

  @State allVideos: VideoItem[] = [];
  @State folders: string[] =[];
  @State currentFolder: string = '';
  @State currentFolderVideos: VideoItem[] =[];

  @State currentPlayIndex: number = 0;
  @State autoPlayNext: boolean = true;
  @State showPlaylistSheet: boolean = false;

  private avPlayer: media.AVPlayer | undefined = undefined;
  private xComponentController: XComponentController = new XComponentController();
  @State surfaceId: string = '';
  @State currentSubtitle: string = '';
  @State isVideoLoaded: boolean = false;
  @State isPlaying: boolean = false;
  @State currentTime: number = 0;
  @State duration: number = 0;
  @State isDragging: boolean = false;
  @State volume: number = 100;
  @State speedText: string = '1.0x';
  @State speedMode: number = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
  @State isFullScreen: boolean = false;
  @State showControls: boolean = true;
  @State isSubtitleEnabled: boolean = true;
  @State videoRatio: number = 1.777;

  private hideTimer: number = -1;
  private videoFd: number = -1;
  private srtFd: number = -1;

  async aboutToAppear() {
    this.loadLibrary();
  }

  loadLibrary() {
    try {
      if (this.virtualFilesJson !== '' && this.virtualFilesJson !== '[]') {
        this.allVideos = JSON.parse(this.virtualFilesJson);
      }
      this.refreshFolders();
    } catch (e) {}
  }

  refreshFolders() {
    let folderSet: Set<string> = new Set();
    for (let v of this.allVideos) {
      folderSet.add(v.folderName);
    }
    this.folders = Array.from(folderSet).sort();

    if (this.folders.length > 0 && !this.folders.includes(this.currentFolder)) {
      this.currentFolder = this.folders[0];
    }
    this.updateCurrentFolderVideos();
  }

  updateCurrentFolderVideos() {
    let list: VideoItem[] = this.allVideos.filter(v => v.folderName === this.currentFolder);
    list.sort((a, b) => a.name.localeCompare(b.name, 'zh-CN', { numeric: true }));
    this.currentFolderVideos = list;
  }

  // 严格模式修复：明确返回类型为 UriInfo
  parseUriInfo(uri: string): UriInfo {
    let decoded: string = decodeURIComponent(uri);
    let parts: string[] = decoded.split('/');
    let name: string = parts[parts.length - 1];
    let folderName: string = parts.length > 1 ? parts[parts.length - 2] : '默认文件夹';
    let baseName: string = name.includes('.') ? name.substring(0, name.lastIndexOf('.')) : name;

    let info: UriInfo = { name: name, folderName: folderName, baseName: baseName };
    return info;
  }

  async importVideos() {
    try {
      let context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let pickerObj: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      let uris: Array<string> = await pickerObj.select({ maxSelectNumber: 500, fileSuffixFilters:['.mp4', '.mkv', '.avi'] });

      if (!uris || uris.length === 0) return;

      for (let uri of uris) {
        let info = this.parseUriInfo(uri);
        if (!this.allVideos.find(v => v.videoUri === uri)) {
          // 严格模式修复：必须显式声明类型后推入数组
          let newItem: VideoItem = {
            videoUri: uri,
            name: info.name,
            baseName: info.baseName,
            folderName: info.folderName,
            srtUri: null,
            srtName: null
          };
          this.allVideos.push(newItem);
        }
      }

      this.virtualFilesJson = JSON.stringify(this.allVideos);
      this.refreshFolders();
      if (uris.length > 0) this.currentFolder = this.parseUriInfo(uris[0]).folderName;
      this.updateCurrentFolderVideos();
    } catch (err) {}
  }

  async importSubtitles() {
    try {
      let context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let pickerObj: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      let uris: Array<string> = await pickerObj.select({ maxSelectNumber: 500, fileSuffixFilters: ['.srt', '.vtt'] });

      if (!uris || uris.length === 0) return;

      let matchCount: number = 0;
      for (let subUri of uris) {
        let subInfo = this.parseUriInfo(subUri);
        for (let i = 0; i < this.allVideos.length; i++) {
          let video = this.allVideos[i];
          if (video.folderName === subInfo.folderName) {
            let sBase = subInfo.baseName.toLowerCase();
            let vBase = video.baseName.toLowerCase();
            if (sBase.includes(vBase) || vBase.includes(sBase)) {
              this.allVideos[i].srtUri = subUri;
              this.allVideos[i].srtName = subInfo.name;
              matchCount++;
              break;
            }
          }
        }
      }

      this.virtualFilesJson = JSON.stringify(this.allVideos);
      this.updateCurrentFolderVideos();

      // 修复 WARN 提示：废弃 AlertDialog.show，改用更现代的系统级 Toast 提示
      promptAction.showToast({
        message: `配对成功！为当前目录匹配了 ${matchCount} 个字幕文件。`,
        duration: 3000
      });
    } catch (err) {}
  }

  clearLibrary() {
    this.allVideos = [];
    this.folders =[];
    this.currentFolder = '';
    this.currentFolderVideos = [];
    this.virtualFilesJson = '[]';
  }

  async enterPlayer(index: number, seekTime: number = 0) {
    this.currentPlayIndex = index;
    this.currentView = 'PLAYER';
    this.showPlaylistSheet = false;

    try {
      if (!this.avPlayer) {
        this.avPlayer = await media.createAVPlayer();
        this.setAVPlayerCallback();
      }
      let context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let win: window.Window = await window.getLastWindow(context);
      await win.setWindowSystemBarEnable([]);
      this.isFullScreen = true;

      setTimeout(() => {
        this.loadVideoByIndex(this.currentPlayIndex, seekTime);
      }, 200);
    } catch (e) {}
  }

  async exitPlayer() {
    if (this.currentFolderVideos.length > 0) {
      this.lastPlayUri = this.currentFolderVideos[this.currentPlayIndex].videoUri;
      this.lastPlayTime = this.currentTime;
    }

    try {
      if (this.avPlayer) {
        await this.avPlayer.release();
        this.avPlayer = undefined;
      }
      let context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let win: window.Window = await window.getLastWindow(context);
      await win.setWindowSystemBarEnable(['status', 'navigation']);
    } catch (e) {}

    this.currentView = 'HOME';
  }

  setAVPlayerCallback() {
    if (!this.avPlayer) return;

    this.avPlayer.on('videoSizeChange', (width: number, height: number) => {
      if (height > 0) this.videoRatio = width / height;
    });

    this.avPlayer.on('stateChange', async (state: string) => {
      try {
        switch (state) {
          case 'initialized':
            this.avPlayer!.surfaceId = this.surfaceId;
            if (this.srtFd !== -1) {
              let srtSize: number = fs.statSync(this.srtFd).size;
              this.avPlayer!.addSubtitleFromFd(this.srtFd, 0, srtSize);
            }
            this.avPlayer!.prepare();
            break;
          case 'prepared':
            this.isVideoLoaded = true;
            this.duration = this.avPlayer!.duration;
            this.avPlayer!.setSpeed(this.speedMode);
            this.avPlayer!.play();
            this.isPlaying = true;
            break;
          case 'playing':
            this.isPlaying = true;
            break;
          case 'paused':
            this.isPlaying = false;
            break;
          case 'completed':
            this.isPlaying = false;
            if (this.autoPlayNext && this.currentPlayIndex < this.currentFolderVideos.length - 1) {
              this.currentPlayIndex++;
              this.loadVideoByIndex(this.currentPlayIndex, 0);
            } else {
              this.showControls = true;
            }
            break;
        }
      } catch (err) {}
    });

    this.avPlayer.on('timeUpdate', (time: number) => {
      if (!this.isDragging) this.currentTime = time;
    });

    this.avPlayer.on('subtitleUpdate', (info: media.SubtitleInfo) => {
      this.currentSubtitle = (info && info.text) ? info.text : '';
    });
  }

  async loadVideoByIndex(index: number, startSeek: number = 0) {
    if (!this.avPlayer || index >= this.currentFolderVideos.length) return;
    let item: VideoItem = this.currentFolderVideos[index];

    try {
      await this.avPlayer.reset();
      this.currentSubtitle = '';
      this.isVideoLoaded = false;
      this.currentTime = startSeek;

      if (item.srtUri) {
        try {
          let srtFile: fs.File = fs.openSync(item.srtUri, fs.OpenMode.READ_ONLY);
          this.srtFd = srtFile.fd;
        } catch (e) { this.srtFd = -1; }
      } else {
        this.srtFd = -1;
      }

      try {
        let videoFile: fs.File = fs.openSync(item.videoUri, fs.OpenMode.READ_ONLY);
        this.videoFd = videoFile.fd;
        this.avPlayer.fdSrc = { fd: this.videoFd };
      } catch (e) {}

      if (startSeek > 0) {
        let seekCheck = setInterval(() => {
          try {
            if (this.isVideoLoaded && this.avPlayer) {
              this.avPlayer.seek(startSeek, media.SeekMode.SEEK_CLOSEST);
              clearInterval(seekCheck);
            }
          } catch(e) { clearInterval(seekCheck); }
        }, 200);
      }
      this.resetHideTimer();
    } catch (err) {}
  }

  resetHideTimer() {
    clearTimeout(this.hideTimer);
    if (this.showControls) {
      this.hideTimer = setTimeout(() => {
        if (this.isPlaying && !this.showPlaylistSheet) this.showControls = false;
      }, 5000);
    }
  }

  togglePlay() {
    if (!this.avPlayer || !this.isVideoLoaded) return;
    try {
      this.isPlaying ? this.avPlayer.pause() : this.avPlayer.play();
      this.resetHideTimer();
    } catch (e) {}
  }

  formatTime(ms: number): string {
    let ts: number = Math.floor(ms / 1000);
    let h: number = Math.floor(ts / 3600);
    let m: number = Math.floor((ts % 3600) / 60);
    let s: number = ts % 60;
    let str: string = `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
    return h > 0 ? `${h}:${str}` : str;
  }

  setSpeed(speedStr: string) {
    if (!this.avPlayer) return;
    try {
      let mode: number = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
      switch (speedStr) {
        case '0.75x': mode = media.PlaybackSpeed.SPEED_FORWARD_0_75_X; break;
        case '1.0x': mode = media.PlaybackSpeed.SPEED_FORWARD_1_00_X; break;
        case '1.25x': mode = media.PlaybackSpeed.SPEED_FORWARD_1_25_X; break;
        case '1.5x': mode = media.PlaybackSpeed.SPEED_FORWARD_1_50_X; break;
        case '2.0x': mode = media.PlaybackSpeed.SPEED_FORWARD_2_00_X; break;
      }
      this.speedText = speedStr;
      this.speedMode = mode;
      this.avPlayer.setSpeed(mode);
      this.resetHideTimer();
    } catch (e) {}
  }

  build() {
    if (this.currentView === 'HOME') {
      this.buildHomeView()
    } else {
      this.buildPlayerView()
    }
  }

  @Builder
  buildHomeView() {
    Row() {
      // 左侧导航栏
      Column() {
        Text('📚 我的学习资料')
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#333')
          .padding({ top: 30, left: 20, bottom: 20 }).width('100%').textAlign(TextAlign.Start)

        if (this.folders.length === 0) {
          Text('暂无目录').fontSize(14).fontColor(Color.Gray).margin({ top: 50 })
        } else {
          List() {
            ForEach(this.folders, (folder: string) => {
              ListItem() {
                Row() {
                  Text('📁').fontSize(18).margin({ right: 10 })
                  Text(folder).fontSize(16).fontWeight(this.currentFolder === folder ? FontWeight.Bold : FontWeight.Normal)
                    .fontColor(this.currentFolder === folder ? '#007DFF' : '#333')
                    .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%').padding(15)
                .backgroundColor(this.currentFolder === folder ? 'rgba(0,125,255,0.1)' : 'transparent')
                .borderRadius(8)
              }
              .onClick(() => {
                this.currentFolder = folder;
                this.updateCurrentFolderVideos();
              })
            })
          }.width('100%').layoutWeight(1).padding({ left: 10, right: 10 })
        }

        Blank()
        Button('🗑️ 清空媒体库').backgroundColor(Color.Transparent).fontColor(Color.Red).fontSize(14).margin({ bottom: 20 })
          .onClick(() => this.clearLibrary())
      }
      .width(260).height('100%').backgroundColor('#F3F4F5')

      Divider().vertical(true).color('#E5E5E5')

      // 右侧文件区
      Column() {
        // 顶部操作栏
        Row() {
          Text(this.currentFolder || '请先导入文件').fontSize(24).fontWeight(FontWeight.Medium).fontColor('#333')
          Blank()
          Button('1.导入视频 (.mp4)').backgroundColor('#007DFF').margin({ right: 15 }).onClick(() => this.importVideos())
          Button('2.导入匹配字幕').backgroundColor('#00A354').onClick(() => this.importSubtitles())
        }.width('100%').padding(20).border({ width: { bottom: 1 }, color: '#E5E5E5' })

        // 解决 ERROR 2：将逻辑判断内联，完全剥离 let 的定义
        if (this.lastPlayUri !== '' && this.currentFolderVideos.some(v => v.videoUri === this.lastPlayUri)) {
          Row() {
            Text('上次观看到：' + (this.currentFolderVideos.find(v => v.videoUri === this.lastPlayUri)?.name || '未知文件'))
              .fontSize(14).fontColor('#007DFF').layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('继续播放 ▶').fontSize(14).fontColor('#007DFF').fontWeight(FontWeight.Bold)
          }
          .width('95%').padding(12).margin({ top: 10 }).backgroundColor('rgba(0,125,255,0.1)').borderRadius(8)
          .onClick(() => {
            // 逻辑在 onClick 事件回调内执行是绝对安全的
            let targetIndex: number = this.currentFolderVideos.findIndex(v => v.videoUri === this.lastPlayUri);
            if (targetIndex !== -1) {
              this.enterPlayer(targetIndex, this.lastPlayTime);
            }
          })
        }

        if (this.currentFolderVideos.length > 0) {
          List() {
            ForEach(this.currentFolderVideos, (item: VideoItem, index: number) => {
              ListItem() {
                Row() {
                  Text('🎬').fontSize(24).margin({ right: 15 })
                  Column() {
                    Text(item.name).fontSize(16).fontWeight(FontWeight.Medium).fontColor('#333')
                    Text(item.srtUri ? `✓ 字幕已配对 (${item.srtName})` : '未发现字幕').fontSize(12).fontColor(item.srtUri ? '#00A354' : Color.Gray).margin({ top: 4 })
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                }
                .width('100%').padding(15).border({ width: { bottom: 1 }, color: '#F0F0F0' })
              }
              .onClick(() => this.enterPlayer(index, 0))
            })
          }.width('100%').layoutWeight(1)
        } else {
          Column() {
            Text('📄').fontSize(48).margin({ bottom: 10 })
            Text('该文件夹暂无视频').fontSize(16).fontColor(Color.Gray)
            Text('请点击右上角按钮分批导入视频和字幕').fontSize(14).fontColor(Color.Gray).margin({ top: 5 })
          }.layoutWeight(1).justifyContent(FlexAlign.Center)
        }
      }
      .layoutWeight(1).height('100%').backgroundColor('#FFFFFF')
    }
    .width('100%').height('100%')
  }

  @Builder
  buildPlayerView() {
    Stack({ alignContent: Alignment.Bottom }) {
      Stack({ alignContent: Alignment.Center }) {
        XComponent({ id: 'video_player', type: 'surface', controller: this.xComponentController })
          .onLoad(() => { this.surfaceId = this.xComponentController.getXComponentSurfaceId(); })
          .width(this.videoRatio > 1.52 ? '100%' : 'auto')
          .height(this.videoRatio <= 1.52 ? '100%' : 'auto')
          .aspectRatio(this.videoRatio)
      }.width('100%').height('100%').backgroundColor(Color.Black)
      .onClick(() => {
        this.showControls = !this.showControls;
        if (this.showControls) this.resetHideTimer();
      })

      if (this.currentSubtitle !== '' && this.isSubtitleEnabled) {
        Text(this.currentSubtitle)
          .fontSize(30).fontColor(Color.White).fontWeight(FontWeight.Bold).textAlign(TextAlign.Center)
          .textShadow({ radius: 3, color: Color.Black, offsetX: 2, offsetY: 2 })
          .padding({ left: 20, right: 20 })
          .margin({ bottom: this.showControls ? 110 : 30 })
          .animation({ duration: 200, curve: Curve.EaseInOut })
      }

      if (this.showControls) {
        Column() {
          Row() {
            Text('< 返回').fontColor(Color.White).fontSize(18).fontWeight(FontWeight.Medium).padding({ top: 10, bottom: 10, right: 15 }).onClick(() => this.exitPlayer())
            Text(this.currentFolderVideos[this.currentPlayIndex]?.name || '').fontColor(Color.White).fontSize(18).margin({ left: 15 }).fontWeight(FontWeight.Medium).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          }.width('100%').padding({ top: 20, left: 20, right: 20 }).linearGradient({ direction: GradientDirection.Bottom, colors: [['rgba(0,0,0,0)', 0.0],['rgba(0,0,0,0.6)', 1.0]] })

          Blank()

          Column() {
            Row() {
              Text(this.formatTime(this.currentTime)).fontColor(Color.White).fontSize(14)
              Slider({ value: this.currentTime, min: 0, max: this.duration > 0 ? this.duration : 100 })
                .layoutWeight(1).selectedColor('#007DFF').trackColor(Color.Gray)
                .onChange((value: number, mode: SliderChangeMode) => {
                  try {
                    if (mode === SliderChangeMode.Begin) this.isDragging = true;
                    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                      if (this.avPlayer) this.avPlayer.seek(value, media.SeekMode.SEEK_CLOSEST);
                      this.currentTime = value;
                      this.isDragging = false;
                    }
                    this.resetHideTimer();
                  } catch (err) {}
                })
              Text(this.formatTime(this.duration)).fontColor(Color.White).fontSize(14)
            }.width('100%').padding({ left: 15, right: 15 })

            Row() {
              Text(this.isPlaying ? '⏸' : '▶').fontSize(30).fontColor(Color.White).onClick(() => this.togglePlay())

              Blank()

              Text('选集').fontColor(Color.White).fontSize(16).margin({ right: 25 }).onClick(() => { this.showPlaylistSheet = true; this.showControls = false; })
              Text(this.isSubtitleEnabled ? '字幕: 开' : '字幕: 关').fontColor(Color.White).fontSize(16).margin({ right: 25 }).onClick(() => { this.isSubtitleEnabled = !this.isSubtitleEnabled; this.resetHideTimer(); })
              Text('倍速 ' + this.speedText).fontColor(Color.White).fontSize(16).bindMenu([
                { value: '0.75x', action: () => { this.setSpeed('0.75x') } },
                { value: '1.0x', action: () => { this.setSpeed('1.0x') } },
                { value: '1.25x', action: () => { this.setSpeed('1.25x') } },
                { value: '1.5x', action: () => { this.setSpeed('1.5x') } },
                { value: '2.0x', action: () => { this.setSpeed('2.0x') } }
              ])
            }.width('100%').padding({ left: 15, right: 15, bottom: 15, top: 5 })
          }.width('100%').linearGradient({ direction: GradientDirection.Top, colors: [['rgba(0,0,0,0)', 0.0],['rgba(0,0,0,0.8)', 1.0]] })
        }.width('100%').height('100%').transition(TransitionEffect.OPACITY.animation({ duration: 300 }))
      }
    }.width('100%').height('100%').backgroundColor(Color.Black)
    .bindSheet($$this.showPlaylistSheet, this.playlistSheet(), { height: '70%', backgroundColor: '#222', title: { title: '视频选集' }, dragBar: true })
  }

  @Builder
  playlistSheet() {
    Column() {
      Row() {
        Text('自动连播下一集').fontColor(Color.White).fontSize(16).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.autoPlayNext }).selectedColor('#007DFF').onChange((isOn: boolean) => { this.autoPlayNext = isOn; })
      }.width('100%').padding(20)

      List({ space: 10 }) {
        ForEach(this.currentFolderVideos, (item: VideoItem, index: number) => {
          ListItem() {
            Row() {
              Text(`${index + 1}. ${item.name}`).fontColor(this.currentPlayIndex === index ? '#007DFF' : Color.White).fontSize(16).layoutWeight(1)
              if (this.currentPlayIndex === index) { Text('▶').fontSize(20).fontColor('#007DFF') }
            }
            .width('100%').padding(15).backgroundColor(this.currentPlayIndex === index ? 'rgba(0,125,255,0.1)' : '#333').borderRadius(8)
          }
          .onClick(() => {
            if (this.currentPlayIndex !== index) { this.loadVideoByIndex(index, 0); this.currentPlayIndex = index; }
            this.showPlaylistSheet = false;
          })
        })
      }.padding({ left: 20, right: 20, bottom: 20 }).layoutWeight(1)
    }.width('100%').height('100%')
  }
}
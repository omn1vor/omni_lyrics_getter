import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;

class Song {
  final String title;
  final String author;
  final String albumImgURL;
  String text = '';

  Song(this.title, this.author, this.albumImgURL);

  Song.fromJson(Map<dynamic, dynamic> json)
      : title = json['track']['title'],
        author = json['track']['subtitle'],
        albumImgURL = json['track']['images']['coverart'] ?? '';

  Map<String, dynamic> toJson() => {
        'title': title,
        'author': author,
        'albumImgURL': albumImgURL,
        'text': text
      };
}

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OmniLyricsGetter',
      theme: ThemeData(primarySwatch: Colors.blue,),
      home: MyHomePage(title: 'Omni lyrics getter'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({this.title = ''});

  final String title;

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final FlutterSoundRecorder _myRecorder = FlutterSoundRecorder();
  final int _maxAttempts = 5;
  int _currentAttempt = 0;
  Timer? _timer;
  bool _songRecognized = false;
  bool _recordAvailable = false;
  bool _recorderReady = false;
  bool _recordingNow = false;
  Song _song = new Song('', '', '');
  String _errorText = '';

  Future<String> get _localFilePath async {
    final directory = await getApplicationDocumentsDirectory();
    return directory.path + '/recording.wav';
  }

  void _newRecord() {
    setState(() {
      _currentAttempt = 0;
      _songRecognized = false;
      _song = new Song('', '', '');
    });
    _record();
  }

  Future<void> _record() async {
    if (!_recorderReady) {
      return;
    }

    if (_currentAttempt > _maxAttempts) {
      setState(() {
        _recordingNow = false;
        _errorText =
            'Could not recognize the song after $_maxAttempts attempts, have to stop trying now :(';
      });
      return;
    }

    await _myRecorder.startRecorder(
        toFile: await _localFilePath,
        codec: Codec.pcm16,
        sampleRate: 44100,
        bitRate: 16,
        numChannels: 1);

    setState(() {
      _recordingNow = true;
      if (_currentAttempt == 0) {
        _song = new Song('', '', '');
      }
      _timer = Timer(Duration(seconds: 5), _stopRecorder);
      _currentAttempt++;
    });
  }

  void _manualStop() {
    _stopRecorder(true);
  }

  Future<void> _stopRecorder([bool manual = false]) async {
    await _myRecorder.stopRecorder();

    if (!manual && !_songRecognized) {
      _getSongData();
      _record();
    }

    setState(() {
      _recordingNow = false;
      _recordAvailable = true;
      if (manual) {
        _timer?.cancel();
        _timer = null;
      }
    });
  }

  Future<void> _initializeRecorder() async {
    var status = await Permission.microphone.request();
    if (status != PermissionStatus.granted) {
      throw RecordingPermissionException('Microphone permission not granted');
    }

    await _myRecorder.openAudioSession();
  }

  Future<http.Response> _sendSongRequest() async {
    final String path = await _localFilePath;
    final File myFile = File.fromUri(Uri.parse(path));
    final Uint8List bytesRead = await myFile.readAsBytes();

    return http.post(Uri.parse('https://shazam.p.rapidapi.com/songs/detect'),
        headers: <String, String>{
          'content-type': 'text/plain',
          'x-rapidapi-key':
              'your key goes here',
          'x-rapidapi-host': 'shazam.p.rapidapi.com',
          'useQueryString': 'true'
        },
        body: base64Encode(bytesRead));
  }

  Future<void> _getSongData() async {
    if (!_recordAvailable || _songRecognized) {
      return;
    }

    final response = await _sendSongRequest();

    if (response.statusCode == 200) {
      Map responseMap = jsonDecode(response.body);
      setState(() {
        _songRecognized = true;
        _song = Song.fromJson(responseMap);
      });
      _getSongLyrics();
    } else {
      setState(() {
        _errorText = 'cannot load song info: ${response.body}';
      });
    }
  }

  Future<http.Response> _sendLyricsRequest() async {
    return http.get(Uri.parse(Uri.encodeFull(
        'http://api.chartlyrics.com/apiv1.asmx/SearchLyricDirect?artist=${_song.author}&song=${_song.title}')));
  }

  Future<void> _getSongLyrics() async {
    final response = await _sendLyricsRequest();
    final RegExp exp = RegExp(r"<Lyric>([^]+)</Lyric>");

    if (response.statusCode == 200) {
      RegExpMatch? match = exp.firstMatch(response.body);
      if (match != null) {
        setState(() {
          _song.text = match.group(1) ?? '';
          if (_song.text == '') {
            _errorText = 'we got the response from the lyrics API, but couldn\'t get the text from it.';
            debugPrint(response.body);
          }
        });
      } else {
        setState(() {
          _errorText = 'cannot load song lyrics: no <Lyrics> tag found';
        });
      }
    } else {
      setState(() {
        _errorText = 'cannot load song lyrics: ${response.body}';
        debugPrint(_song.toString());
      });
    }
  }

  @override
  void initState() {
    super.initState();
    // Be careful : openAudioSession return a Future.
    // Do not access your FlutterSoundPlayer or FlutterSoundRecorder before the completion of the Future

    _initializeRecorder().then((value) {
      setState(() {
        _recorderReady = true;
      });
    });
  }

  @override
  void dispose() {
    // Be careful : you must `close` the audio session when you have finished with it.
    _myRecorder.closeAudioSession();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    //
    return Scaffold(
      appBar: AppBar(
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            _recordingNow
                ? Text(
                    'Recognizing the song, please wait (or press the button to stop recognizing now):')
                : Text('Press to start listening to the song:'),
            _recordingNow
                ? IconButton(
                    icon: Icon(Icons.stop_outlined),
                    onPressed: _manualStop,
                    iconSize: 48,
                  )
                : IconButton(
                    icon: Icon(Icons.fiber_manual_record_outlined),
                    onPressed: _newRecord,
                    iconSize: 48,
                  ),
            (_song.albumImgURL == '')
                ? new Container()
                : Image(
              image: NetworkImage(_song.albumImgURL),
              height: 150,
            ),
            (_errorText == '') ? new Container() : Text('Error: $_errorText'),
            (_songRecognized)
                ? Text('Song recognized: \n${_song.title} by ${_song.author}', textScaleFactor: 1.5,)
                : new Container(),

            new Expanded(
                flex: 1,
                child: new SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: Container(
                      decoration: BoxDecoration(
                        color: Color(0xFFA3D1FC),
                      ),
                      child: new Text(_song.text, textScaleFactor: 1.7,)),
                ))
          ],
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_cube/flutter_cube.dart';
import 'package:motion_sensors/motion_sensors.dart';
import 'package:panorama/math_utils.dart';

enum SensorControl {
  /// No sensor used.
  none,

  /// Use gyroscope and accelerometer.
  orientation,

  /// Use magnetometer and accelerometer. The longitude 0 points to north.
  absoluteOrientation,
}

class Panorama extends StatefulWidget {
  const Panorama({
    super.key,
    this.latitude = 0,
    this.longitude = 0,
    this.zoom = 1.0,
    this.minLatitude = -90.0,
    this.maxLatitude = 90.0,
    this.minLongitude = -180.0,
    this.maxLongitude = 180.0,
    this.minZoom = 1.0,
    this.maxZoom = 5.0,
    this.panInertia = 0.05,
    this.animReverse = true,
    this.latSegments = 32,
    this.lonSegments = 64,
    this.interactive = true,
    this.sensorControl = .none,
    this.sensorOrientationMeanCount = 1,
    this.croppedArea = const Rect.fromLTWH(0.0, 0.0, 1.0, 1.0),
    this.croppedFullWidth = 1.0,
    this.croppedFullHeight = 1.0,
    this.onViewChanged,
    this.onTap,
    this.onLongPressStart,
    this.onLongPressMoveUpdate,
    this.onLongPressEnd,
    this.onImageLoad,
    this.child,
    this.hotspots,
  });

  /// The initial latitude, in degrees, between -90 and 90. default to 0 (the vertical center of the image).
  final double latitude;

  /// The initial longitude, in degrees, between -180 and 180. default to 0 (the horizontal center of the image).
  final double longitude;

  /// The initial zoom, default to 1.0.
  final double zoom;

  /// The minimal latitude to show. default to -90.0
  final double minLatitude;

  /// The maximal latitude to show. default to 90.0
  final double maxLatitude;

  /// The minimal longitude to show. default to -180.0
  final double minLongitude;

  /// The maximal longitude to show. default to 180.0
  final double maxLongitude;

  /// The minimal zoom. default to 1.0
  final double minZoom;

  /// The maximal zoom. default to 5.0
  final double maxZoom;

  /// default to 0.05
  final double panInertia;

  /// Reverse rotation when the current longitude reaches the minimal or maximum. default to true
  final bool animReverse;

  /// The number of vertical divisions of the sphere.
  final int latSegments;

  /// The number of horizontal divisions of the sphere.
  final int lonSegments;

  /// Interact with the panorama. default to true
  final bool interactive;

  /// Control the panorama with motion sensors.
  final SensorControl sensorControl;

  final int sensorOrientationMeanCount;

  /// Area of the image was cropped from the full sized photo sphere.
  final Rect croppedArea;

  /// Original full width from which the image was cropped.
  final double croppedFullWidth;

  /// Original full height from which the image was cropped.
  final double croppedFullHeight;

  /// This event will be called when the view direction has changed, it contains latitude and longitude about the current view.
  final Function(double longitude, double latitude, double tilt)? onViewChanged;

  /// This event will be called when the user has tapped, it contains latitude and longitude about where the user tapped.
  final Function(double longitude, double latitude, double tilt)? onTap;

  /// This event will be called when the user has started a long press, it contains latitude and longitude about where the user pressed.
  final Function(double longitude, double latitude, double tilt)? onLongPressStart;

  /// This event will be called when the user has drag-moved after a long press, it contains latitude and longitude about where the user pressed.
  final Function(double longitude, double latitude, double tilt)? onLongPressMoveUpdate;

  /// This event will be called when the user has stopped a long presses, it contains latitude and longitude about where the user pressed.
  final Function(double longitude, double latitude, double tilt)? onLongPressEnd;

  /// This event will be called when provided image is loaded on texture.
  final Function()? onImageLoad;

  /// Specify an Image(equirectangular image) widget to the panorama.
  final Image? child;

  /// Place widgets in the panorama.
  final List<Hotspot>? hotspots;

  @override
  State<Panorama> createState() => _PanoramaState();
}

class _PanoramaState extends State<Panorama> with SingleTickerProviderStateMixin {
  Scene? scene;
  Object? surface;
  late double latitudeRad;
  late double longitudeRad;
  double latitudeDelta = 0;
  double longitudeDelta = 0;
  double zoomDelta = 0;
  late Offset _lastFocalPoint;
  double? _lastZoom;
  final double _animateDirection = 1.0;
  late AnimationController _controller;
  double screenOrientationRad = 0.0;
  Vector3 orientation = Vector3(0, radians(90), 0);
  StreamSubscription? _orientationSubscription;
  StreamSubscription? _screenOrientSubscription;
  late StreamController<Null> _streamController;
  Stream<Null>? _stream;
  ImageStream? _imageStream;
  bool _scaling = false;
  final List<Vector3> _sensorOrientationEvents = [];

  static const double _halfPi = math.pi * .5;
  static const double _epsilon = .001;
  static const double _radius = 500;
  static const double _panReactivity = .8;

  void _handleTapUp(TapUpDetails details) {
    final Vector3 o = positionToLatLon(details.localPosition.dx, details.localPosition.dy);
    widget.onTap!(degrees(o.x), degrees(-o.y), degrees(o.z));
  }

  void _handleLongPressStart(LongPressStartDetails details) {
    final Vector3 o = positionToLatLon(details.localPosition.dx, details.localPosition.dy);
    widget.onLongPressStart!(degrees(o.x), degrees(-o.y), degrees(o.z));
  }

  void _handleLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    final Vector3 o = positionToLatLon(details.localPosition.dx, details.localPosition.dy);
    widget.onLongPressMoveUpdate!(degrees(o.x), degrees(-o.y), degrees(o.z));
  }

  void _handleLongPressEnd(LongPressEndDetails details) {
    final Vector3 o = positionToLatLon(details.localPosition.dx, details.localPosition.dy);
    widget.onLongPressEnd!(degrees(o.x), degrees(-o.y), degrees(o.z));
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _lastFocalPoint = details.localFocalPoint;
    _lastZoom = null;
    _scaling = true;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    final offset = details.localFocalPoint - _lastFocalPoint;
    _lastFocalPoint = details.localFocalPoint;
    _updatePositionDeltaForOffset(offset);

    final zoom = scene!.camera.zoom;
    _lastZoom ??= zoom;
    zoomDelta += _lastZoom! * details.scale - (zoom + zoomDelta);

    if (widget.sensorControl == .none && !_controller.isAnimating) {
      _controller.reset();
      _controller.forward();
    }
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    final offset = details.velocity.pixelsPerSecond / 10;
    _updatePositionDeltaForOffset(offset);
    _scaling = false;
  }

  void _updatePositionDeltaForOffset(ui.Offset offset) {
    final camera = scene!.camera;
    final sensitivity = 1 / camera.zoom;
    final viewportHeight = camera.viewportHeight;

    latitudeDelta += sensitivity * _halfPi * offset.dy / viewportHeight;
    longitudeDelta -= sensitivity * _animateDirection * _halfPi * offset.dx / viewportHeight;
  }

  void _updateView() {
    if (scene == null) return;

    final camera = scene!.camera;
    final damping = _scaling ? _panReactivity : widget.panInertia;

    // animate vertical rotating
    latitudeRad += latitudeDelta * damping;
    latitudeDelta *= 1 - damping;

    // animate horizontal rotating
    longitudeRad += _animateDirection * longitudeDelta * damping;
    longitudeDelta *= 1 - damping;

    // animate zooming
    final double zoom = camera.zoom + zoomDelta * damping;
    zoomDelta *= 1 - damping;
    camera.zoom = zoom.clamp(widget.minZoom, widget.maxZoom);

    // stop animation if not needed
    if (latitudeDelta.abs() < _epsilon && longitudeDelta.abs() < _epsilon && zoomDelta.abs() < _epsilon) {
      if (widget.sensorControl == .none && _controller.isAnimating) {
        _controller.stop();
      }
    }

    // rotate for screen orientation
    Quaternion q = Quaternion.axisAngle(Vector3(0, 0, 1), screenOrientationRad);
    // rotate for device orientation
    q *= Quaternion.euler(-orientation.z, -orientation.y, -orientation.x);
    // rotate to latitude zero
    q *= Quaternion.axisAngle(Vector3(1, 0, 0), _halfPi);

    // check and limit the rotation range
    Vector3 o = quaternionToOrientation(q);
    final double minLat = radians(math.max(-89.9, widget.minLatitude));
    final double maxLat = radians(math.min(89.9, widget.maxLatitude));
    final double minLon = radians(widget.minLongitude);
    final double maxLon = radians(widget.maxLongitude);
    final double lat = (-o.y).clamp(minLat, maxLat);
    final double lon = o.x.clamp(minLon, maxLon);
    if (lat + latitudeRad < minLat) latitudeRad = minLat - lat;
    if (lat + latitudeRad > maxLat) latitudeRad = maxLat - lat;
    if (maxLon - minLon < math.pi * 2) {
      if (lon + longitudeRad < minLon || lon + longitudeRad > maxLon) {
        longitudeRad = (lon + longitudeRad < minLon ? minLon : maxLon) - lon;
      }
    }
    o.x = lon;
    o.y = -lat;
    q = orientationToQuaternion(o);

    // rotate to longitude zero
    q *= Quaternion.axisAngle(Vector3(0, 1, 0), -_halfPi);
    // rotate around the global Y axis
    q *= Quaternion.axisAngle(Vector3(0, 1, 0), longitudeRad);
    // rotate around the local X axis
    q = Quaternion.axisAngle(Vector3(1, 0, 0), -latitudeRad) * q;

    o = quaternionToOrientation(q * Quaternion.axisAngle(Vector3(0, 1, 0), _halfPi));
    widget.onViewChanged?.call(degrees(o.x), degrees(-o.y), degrees(o.z));

    q.rotate(camera.target..setFrom(Vector3(0, 0, -_radius)));
    q.rotate(camera.up..setFrom(Vector3(0, 1, 0)));
    scene!.update();
    _streamController.add(null);
  }

  void _updateSensorControl() {
    _orientationSubscription?.cancel();
    switch (widget.sensorControl) {
      case .orientation:
        motionSensors.orientationUpdateInterval = Duration.microsecondsPerSecond ~/ 60;
        _orientationSubscription = motionSensors.orientation.listen((event) {
          orientation.setFrom(_saveSensorOrientation(event.yaw, event.pitch, event.roll));
          _updateView();
        });
        break;
      case .absoluteOrientation:
        motionSensors.absoluteOrientationUpdateInterval = Duration.microsecondsPerSecond ~/ 60;
        _orientationSubscription = motionSensors.absoluteOrientation.listen((event) {
          orientation.setFrom(_saveSensorOrientation(event.yaw, event.pitch, event.roll));
          _updateView();
        });
        break;
      default:
    }

    _screenOrientSubscription?.cancel();
    if (widget.sensorControl != .none) {
      _screenOrientSubscription = motionSensors.screenOrientation.listen((event) {
        screenOrientationRad = radians(event.angle!);
      });
    }
  }

  // return rolling average
  Vector3 _saveSensorOrientation(double yaw, double pitch, double roll) {
    _sensorOrientationEvents.add(Vector3(yaw, pitch, roll));

    final meanCount = widget.sensorOrientationMeanCount;
    while (_sensorOrientationEvents.length > meanCount) {
      _sensorOrientationEvents.removeAt(0);
    }

    if (_sensorOrientationEvents.length > 1) {
      final yawMean = circularMean(_sensorOrientationEvents.map((v) => v.x));
      final pitchMean = circularMean(_sensorOrientationEvents.map((v) => v.y));
      final rollMean = circularMean(_sensorOrientationEvents.map((v) => v.z));
      return Vector3(yawMean, pitchMean, rollMean);
    } else {
      return _sensorOrientationEvents.first;
    }
  }

  void _updateTexture(ImageInfo imageInfo, bool synchronousCall) {
    surface?.mesh.texture = imageInfo.image;
    surface?.mesh.textureRect = Rect.fromLTWH(0, 0, imageInfo.image.width.toDouble(), imageInfo.image.height.toDouble());
    scene!.texture = imageInfo.image;
    scene!.update();
    widget.onImageLoad?.call();
  }

  void _loadTexture(ImageProvider? provider) {
    if (provider == null) return;
    _imageStream?.removeListener(ImageStreamListener(_updateTexture));
    _imageStream = provider.resolve(const ImageConfiguration());
    ImageStreamListener listener = ImageStreamListener(_updateTexture);
    _imageStream!.addListener(listener);
  }

  void _onSceneCreated(Scene scene) {
    this.scene = scene;
    final camera = scene.camera;
    camera.near = 1.0;
    camera.far = _radius + 1.0;
    camera.fov = 75;
    camera.zoom = widget.zoom;
    camera.position.setFrom(Vector3(0, 0, 0.1));
    if (widget.child != null) {
      final Mesh mesh = generateSphereMesh(
        radius: _radius,
        latSegments: widget.latSegments,
        lonSegments: widget.lonSegments,
        croppedArea: widget.croppedArea,
        croppedFullWidth: widget.croppedFullWidth,
        croppedFullHeight: widget.croppedFullHeight,
      );
      surface = Object(name: 'surface', mesh: mesh, backfaceCulling: false);
      _loadTexture(widget.child!.image);
      scene.world.add(surface!);
      _updateView();
    }
  }

  Matrix4 matrixFromLatLon(double lat, double lon) {
    return Matrix4.rotationY(radians(90.0 - lon))..rotateX(radians(lat));
  }

  Vector3 positionToLatLon(double x, double y) {
    final camera = scene!.camera;

    // transform viewport coordinate to NDC, values between -1 and 1
    final v = Vector4(2.0 * x / camera.viewportWidth - 1.0, 1.0 - 2.0 * y / camera.viewportHeight, 1.0, 1.0);
    // create projection matrix
    final m = camera.projectionMatrix * camera.lookAtMatrix;
    // apply inverse projection matrix
    m.invert();
    v.applyMatrix4(m);
    // apply perspective division
    v.scale(1 / v.w);
    // get rotation from two vectors
    final q = Quaternion.fromTwoVectors(v.xyz, Vector3(0.0, 0.0, -_radius));
    // get euler angles from rotation
    return quaternionToOrientation(q * Quaternion.axisAngle(Vector3(0, 1, 0), _halfPi));
  }

  Vector3 positionFromLatLon(double lat, double lon) {
    final camera = scene!.camera;

    // create projection matrix
    final Matrix4 m = camera.projectionMatrix * camera.lookAtMatrix * matrixFromLatLon(lat, lon);
    // apply projection matrix
    final Vector4 v = Vector4(0.0, 0.0, -_radius, 1.0)..applyMatrix4(m);
    // apply perspective division and transform NDC to the viewport coordinate
    return Vector3(
      (1.0 + v.x / v.w) * camera.viewportWidth / 2,
      (1.0 - v.y / v.w) * camera.viewportHeight / 2,
      v.z,
    );
  }

  Widget buildHotspotWidgets(List<Hotspot>? hotspots) {
    final widgets = <Widget>[];
    if (hotspots != null && scene != null) {
      for (Hotspot hotspot in hotspots) {
        final pos = positionFromLatLon(hotspot.latitude, hotspot.longitude);
        final origin = Offset(hotspot.width * hotspot.origin.dx, hotspot.height * hotspot.origin.dy);
        final transform = scene!.camera.lookAtMatrix * matrixFromLatLon(hotspot.latitude, hotspot.longitude);
        final child = Positioned(
          left: pos.x - origin.dx,
          top: pos.y - origin.dy,
          width: hotspot.width,
          height: hotspot.height,
          child: Transform(
            origin: origin,
            transform: transform..invert(),
            child: Offstage(
              offstage: pos.z < 0,
              child: hotspot.widget,
            ),
          ),
        );
        widgets.add(child);
      }
    }
    return Stack(children: widgets);
  }

  @override
  void initState() {
    super.initState();
    latitudeRad = radians(widget.latitude);
    longitudeRad = radians(widget.longitude);
    _streamController = StreamController<Null>.broadcast();
    _stream = _streamController.stream;

    _updateSensorControl();

    _controller = AnimationController(duration: const Duration(milliseconds: 60000), vsync: this)..addListener(_updateView);
    if (widget.sensorControl != .none) _controller.repeat();
  }

  @override
  void dispose() {
    _imageStream?.removeListener(ImageStreamListener(_updateTexture));
    _orientationSubscription?.cancel();
    _screenOrientSubscription?.cancel();
    _controller.dispose();
    _streamController.close();
    super.dispose();
  }

  @override
  void didUpdateWidget(Panorama oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (surface == null) return;
    if (widget.latSegments != oldWidget.latSegments ||
        widget.lonSegments != oldWidget.lonSegments ||
        widget.croppedArea != oldWidget.croppedArea ||
        widget.croppedFullWidth != oldWidget.croppedFullWidth ||
        widget.croppedFullHeight != oldWidget.croppedFullHeight) {
      surface!.mesh = generateSphereMesh(
        radius: _radius,
        latSegments: widget.latSegments,
        lonSegments: widget.lonSegments,
        croppedArea: widget.croppedArea,
        croppedFullWidth: widget.croppedFullWidth,
        croppedFullHeight: widget.croppedFullHeight,
      );
    }
    if (widget.child?.image != oldWidget.child?.image) {
      _loadTexture(widget.child?.image);
    }
    if (widget.sensorControl != oldWidget.sensorControl) {
      _updateSensorControl();
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget pano = Stack(
      children: [
        Cube(interactive: false, onSceneCreated: _onSceneCreated),
        StreamBuilder(
          stream: _stream,
          builder: (context, snapshot) {
            return buildHotspotWidgets(widget.hotspots);
          },
        ),
      ],
    );

    return widget.interactive
        ? GestureDetector(
            onScaleStart: _handleScaleStart,
            onScaleUpdate: _handleScaleUpdate,
            onScaleEnd: _handleScaleEnd,
            onTapUp: widget.onTap == null ? null : _handleTapUp,
            onLongPressStart: widget.onLongPressStart == null ? null : _handleLongPressStart,
            onLongPressMoveUpdate: widget.onLongPressMoveUpdate == null ? null : _handleLongPressMoveUpdate,
            onLongPressEnd: widget.onLongPressEnd == null ? null : _handleLongPressEnd,
            child: pano,
          )
        : pano;
  }
}

class Hotspot {
  Hotspot({
    this.name,
    this.latitude = 0.0,
    this.longitude = 0.0,
    this.origin = const Offset(0.5, 0.5),
    this.width = 32.0,
    this.height = 32.0,
    this.widget,
  });

  /// The name of this hotspot.
  String? name;

  /// The initial latitude, in degrees, between -90 and 90.
  final double latitude;

  /// The initial longitude, in degrees, between -180 and 180.
  final double longitude;

  /// The local origin of this hotspot. Default is Offset(0.5, 0.5).
  final Offset origin;

  // The width of widget. Default is 32.0
  double width;

  // The height of widget. Default is 32.0
  double height;

  Widget? widget;
}

Mesh generateSphereMesh({num radius = 1.0, int latSegments = 16, int lonSegments = 16, ui.Image? texture, Rect croppedArea = const Rect.fromLTWH(0.0, 0.0, 1.0, 1.0), double croppedFullWidth = 1.0, double croppedFullHeight = 1.0}) {
  int count = (latSegments + 1) * (lonSegments + 1);
  List<Vector3> vertices = List<Vector3>.filled(count, Vector3.zero());
  List<Offset> texcoords = List<Offset>.filled(count, Offset.zero);
  List<Polygon> indices = List<Polygon>.filled(latSegments * lonSegments * 2, Polygon(0, 0, 0));

  int i = 0;
  for (int y = 0; y <= latSegments; ++y) {
    final double tv = y / latSegments;
    final double v = (croppedArea.top + croppedArea.height * tv) / croppedFullHeight;
    final double sv = math.sin(v * math.pi);
    final double cv = math.cos(v * math.pi);
    for (int x = 0; x <= lonSegments; ++x) {
      final double tu = x / lonSegments;
      final double u = (croppedArea.left + croppedArea.width * tu) / croppedFullWidth;
      vertices[i] = Vector3(radius * math.cos(u * math.pi * 2.0) * sv, radius * cv, radius * math.sin(u * math.pi * 2.0) * sv);
      texcoords[i] = Offset(tu, 1.0 - tv);
      i++;
    }
  }

  i = 0;
  for (int y = 0; y < latSegments; ++y) {
    final int base1 = (lonSegments + 1) * y;
    final int base2 = (lonSegments + 1) * (y + 1);
    for (int x = 0; x < lonSegments; ++x) {
      indices[i++] = Polygon(base1 + x, base1 + x + 1, base2 + x);
      indices[i++] = Polygon(base1 + x + 1, base2 + x + 1, base2 + x);
    }
  }

  final Mesh mesh = Mesh(vertices: vertices, texcoords: texcoords, indices: indices, texture: texture);
  return mesh;
}

Vector3 quaternionToOrientation(Quaternion q) {
  // final Matrix4 m = Matrix4.compose(Vector3.zero(), q, Vector3.all(1.0));
  // final Vector v = motionSensors.getOrientation(m);
  // return Vector3(v.z, v.y, v.x);
  final storage = q.storage;
  final double x = storage[0];
  final double y = storage[1];
  final double z = storage[2];
  final double w = storage[3];
  final double roll = math.atan2(-2 * (x * y - w * z), 1.0 - 2 * (x * x + z * z));
  final double pitch = math.asin(2 * (y * z + w * x));
  final double yaw = math.atan2(-2 * (x * z - w * y), 1.0 - 2 * (x * x + y * y));
  return Vector3(yaw, pitch, roll);
}

Quaternion orientationToQuaternion(Vector3 v) {
  final Matrix4 m = Matrix4.identity();
  m.rotateZ(v.z);
  m.rotateX(v.y);
  m.rotateY(v.x);
  return Quaternion.fromRotation(m.getRotation());
}

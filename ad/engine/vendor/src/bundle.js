// One classic script for the ad pages: three.js + the addons we use + an MP4 muxer.
import * as THREE from "three";
import { RoundedBoxGeometry } from "three/examples/jsm/geometries/RoundedBoxGeometry.js";
import { RoomEnvironment } from "three/examples/jsm/environments/RoomEnvironment.js";
import * as Mp4Muxer from "mp4-muxer";
window.THREE = Object.assign({}, THREE, { RoundedBoxGeometry, RoomEnvironment });
window.Mp4Muxer = Mp4Muxer;

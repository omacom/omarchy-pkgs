// Linux builds of electron-native-auth (github.com/clavin/electron-native-auth)
// compile src/addon_none.cc: native auth sessions are unavailable and
// constructing a request throws. This is the same facade in JavaScript.
class AuthRequest {
  static isAvailable() {
    return false;
  }

  constructor() {
    throw new Error('this function is not implemented for this platform');
  }
}

exports.AuthRequest = AuthRequest;

import 'package:integration_test/integration_test.dart';

import '../test/animation_isolation_test.dart' as photo;
import '../test/globe_gesture_test.dart' as globe;
import '../test/location_photo_space_test.dart' as location;
import '../test/photo_interactions_test.dart' as interactions;
import '../test/map_regression_test.dart' as maps;
import '../test/photo_gallery_test.dart' as album;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  photo.main();
  globe.main();
  location.main();
  interactions.main();
  maps.main();
  album.main();
}

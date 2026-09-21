vec2 view_size = inverse(mat2(CANVAS_MATRIX)) * inverse(mat2(SCREEN_MATRIX)) * vec2(1) * 2.0;
for(int i = 0; i < 8; i++) {
	vec2 test_view_size = target_viewport_sizes[i];
	if(test_view_size == vec2(0)) {
		continue;
	}
	int test_id = target_viewport_ids[i];
	vec2 snapped_difference = round((view_size - test_view_size) * 100.0);
	int current_id = int(snapped_difference.x + snapped_difference.y * 10.);
	if(current_id == test_id) {
		VERTEX *= 0.0;
		break;
	}
}
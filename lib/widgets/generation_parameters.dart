class GenerationParameters {
  final String prompt;
  final String negativePrompt;
  final int clipSkip;
  final double cfgScale;
  final double guidance;
  final int width;
  final int height;
  final int sampleMethod;
  final int sampleSteps;
  final int seed;
  final int batchCount;

  GenerationParameters({
    required this.prompt,
    this.negativePrompt = "",
    this.clipSkip = 2,
    this.cfgScale = 1.0,
    this.guidance = 1.0,
    this.width = 256,
    this.height = 192,
    this.sampleMethod = 0,
    this.sampleSteps = 2,
    this.seed = 42,
    this.batchCount = 1,
  });

  Map<String, dynamic> toJson() => {
        'prompt': prompt,
        'negative_prompt': negativePrompt,
        'clip_skip': clipSkip,
        'cfg_scale': cfgScale,
        'guidance': guidance,
        'width': width,
        'height': height,
        'sample_method': sampleMethod,
        'sample_steps': sampleSteps,
        'seed': seed,
        'batch_count': batchCount,
      };

  factory GenerationParameters.fromJson(Map<String, dynamic> json) {
    return GenerationParameters(
      prompt: json['prompt'],
      negativePrompt: json['negative_prompt'],
      clipSkip: json['clip_skip'],
      cfgScale: json['cfg_scale'],
      guidance: json['guidance'],
      width: json['width'],
      height: json['height'],
      sampleMethod: json['sample_method'],
      sampleSteps: json['sample_steps'],
      seed: json['seed'],
      batchCount: json['batch_count'],
    );
  }
}

require 'nokogiri'
require 'addressable/template'
require 'json'
require 'byebug'

# borrowed from Okracoke: 
# https://github.com/NCSU-Libraries/ocracoke/blob/master/app/processing_helpers/hocr_open_annotation_creator.rb

# Rails config fields used in Okracoke code:
# canvas_url_template: "http://scrc.lib.ncsu.edu/sal_staging/canvas/{id}"
# ocracoke_base_url: "https://ocr-staging01.lib.ncsu.edu/ocr/"

# TODO: pbinkley change these to fit Wax context
CANVAS_URL_TEMPLATE = '{{ \'/\' | absolute_url }}img/derivatives/iiif/annotation/recipebook_{id}.json'
OKRACOKE_BASE_URL = '{{ \'/\' | absolute_url }}/img/derivatives/iiif/annotation/recipebook_{id}/'

class HocrOpenAnnotationCreator

  #include CanvasHelpers

  # these two methods imported from CanvasHelpers
  def manifest_canvas_id(id)
    template_string = CANVAS_URL_TEMPLATE
    template = Addressable::Template.new template_string
    template.expand(id: id).to_s
  end

  def manifest_canvas_on_xywh(id, xywh)
    manifest_canvas_id(id) + "#xywh=#{xywh}"
  end


  def initialize(hocr_path, granularity)
    @hocr = File.open(hocr_path){ |f| Nokogiri::XML(f) }
    @identifier = File.basename(hocr_path, '.hocr')
    @granularity = granularity
    @selector = get_selector
  end

  def get_selector
    if @granularity == "word"
     "ocrx_word"
    elsif @granularity == "line"
     "ocr_line"
    elsif @granularity == "paragraph"
      "ocr_par"
    else
      ""
     end
 end

 def resources
    @hocr.xpath(".//*[contains(@class, '#{@selector}')]").map do |chunk|
      text = chunk.text().gsub("\n", ' ').squeeze(' ').strip
      if !text.empty?
        title = chunk['title']
        title_parts = title.split('; ')
        xywh = '0,0,0,0'
        title_parts.each do |title_part|
          if title_part.include?('bbox')
            match_data = /bbox\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/.match title_part
            x = match_data[1].to_i
            y = match_data[2].to_i
            x1 = match_data[3].to_i
            y1 = match_data[4].to_i
            w = x1 - x
            h = y1 - y
            xywh = "#{x},#{y},#{w},#{h}"
          end
        end
        annotation(text, xywh)
       end
    end.compact
  end

  def annotation_list
    {
      :"@context" => "http://iiif.io/api/presentation/2/context.json",
      :"@id" => annotation_list_id,
      :"@type" => "sc:AnnotationList",
      :"@label" => "OCR text granularity of #{@granularity}",
      resources: resources
    }
  end

  def annotation_list_id_base
    File.join OKRACOKE_BASE_URL, @identifier + '-annotation-list-' + @granularity
  end

  def annotation_list_id
    annotation_list_id_base + '.json'
  end

  def annotation(chars, xywh)
    {
      :"@id" => annotation_id(xywh),
      :"@type" => "oa:Annotation",
      motivation: "sc:painting",
      resource: {
        :"@type" => "cnt:ContentAsText",
        format: "text/plain",
        chars: chars
      },
      # TODO: use canvas_url_template
      on: on_canvas(xywh)
    }
  end

  def annotation_id(xywh)
    File.join annotation_list_id_base, xywh
  end

  def on_canvas(xywh)
    manifest_canvas_on_xywh(@identifier, xywh)
  end

  def to_json
    annotation_list.to_json
  end

  def id
    @identifier
  end
end

hocr_annotations = HocrOpenAnnotationCreator.new('./_data/raw_images/recipebook/recipebook/002.hocr', 'paragraph')


File.open("img/derivatives/iiif/annotation/recipebook_#{hocr_annotations.id}_ocr_paragraphs.json","w") do |f|
  f.write(hocr_annotations.to_json)
end

# Update canvas to link to annotations
manifest_path = "./img/derivatives/iiif/recipebook/manifest.json"

raw_yaml, raw_json = File.read(manifest_path).match(/(---\n.+?\n---\n)(.*)/m)[1..2]
manifest = JSON.parse(raw_json)

this_canvas = manifest['sequences'][0]['canvases'].find { |canvas| canvas['@id'] = "{{ '/' | absolute_url }}img/derivatives/iiif/canvas/recipebook_#{hocr_annotations.id}.json" }

# TODO: don't assume there's only ever a single annotationlist

if this_canvas.dig('otherContent', 0, '@id') == "{{ '/' | absolute_url }}img/derivatives/iiif/annotation/recipebook_#{hocr_annotations.id}_ocr_paragraphs.json" 
  puts "AnnotationList #{hocr_annotations.id} already linked in Manifest"
else
  this_canvas['otherContent'] = [{"@id" => "{{ '/' | absolute_url }}img/derivatives/iiif/annotation/recipebook_#{hocr_annotations.id}_ocr_paragraphs.json", "@type" => "sc:AnnotationList"}]

  File.open(manifest_path, 'w') { |f| f.write("#{raw_yaml}#{manifest.to_json}") }
end

puts 'done'
